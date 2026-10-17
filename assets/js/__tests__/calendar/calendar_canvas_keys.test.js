/**
 * Tests for the CalendarCanvas hook's keyboard (hooks/calendar_canvas/keys.js):
 * the grid is one tab stop, arrows move focus and never data, M moves an
 * event with announcements, Delete and Ctrl Z go to the server.
 */
import { afterEach, expect, test, vi } from "vitest";
import { block, event, mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

const press = (key, extra = {}) =>
  document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra }));

afterEach(unmountAll);

test("the grid is one tab stop, and it follows focus across redraws", () => {
  const { el, handlers } = mountHook();
  expect([...el.querySelectorAll('.cal-ev[tabindex="0"]')].map((node) => node.dataset.eventId)).toEqual(["event-1"]);

  block(el, "event-2").focus();
  handlers["calendar:events"](payload());

  expect([...el.querySelectorAll('.cal-ev[tabindex="0"]')].map((node) => node.dataset.eventId)).toEqual(["event-2"]);
});

test("arrow keys move focus between events and change nothing", () => {
  const { el, hook } = mountHook();
  block(el, "event-1").focus();

  press("ArrowDown");
  expect(document.activeElement.dataset.eventId).toBe("event-2");

  press("ArrowRight");
  expect(document.activeElement.dataset.eventId).toBe("event-3");
  expect(hook.pushEventTo).not.toHaveBeenCalled();
});

test("M moves the event with the arrow keys, announcing each step, and Enter saves it", () => {
  const { el, hook, live } = mountHook();
  block(el, "event-1").focus();

  press("m");
  expect(live.textContent).toBe("Moving Design review, Wed 14 Oct, 11:00 to 12:00.");
  expect(block(el, "event-1").classList.contains("is-moving")).toBe(true);

  press("ArrowDown");
  press("ArrowDown");
  expect(live.textContent).toBe("Wed 14 Oct, 11:30 to 12:30");

  press("Enter");
  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-14T11:30", end: "2026-10-14T12:30" }]);
  expect(document.activeElement.dataset.eventId).toBe("event-1");
});

test("Shift changes the length, and Escape cancels and says so", () => {
  const { el, hook, live } = mountHook();
  block(el, "event-1").focus();

  press("m");
  press("ArrowDown", { shiftKey: true });
  expect(live.textContent).toBe("Wed 14 Oct, 11:00 to 12:15");

  press("Escape");
  expect(live.textContent).toBe("Move cancelled. Design review stays at Wed 14 Oct, 11:00 to 12:00.");
  expect(pushes(hook, "calendar:move")).toEqual([]);
  expect(block(el, "event-1").classList.contains("is-moving")).toBe(false);
});

test("Delete asks the server to delete the focused event", () => {
  const { el, hook } = mountHook();
  block(el, "event-1").focus();

  press("Delete");

  expect(pushes(hook, "calendar:delete")).toEqual([{ id: "event-1" }]);
});

test("an event the organiser cannot change ignores M and Delete", () => {
  const readOnly = payload({ events: [event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00", { editable: false })] });
  const { el, hook } = mountHook(readOnly);
  block(el, "event-1").focus();

  press("m");
  press("Delete");

  expect(block(el, "event-1").classList.contains("is-moving")).toBe(false);
  expect(hook.pushEventTo).not.toHaveBeenCalled();
});

test("Ctrl Z asks to undo anywhere but in a text field", () => {
  const { hook } = mountHook();

  document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "z", ctrlKey: true, bubbles: true }));
  expect(pushes(hook, "calendar:undo")).toEqual([{}]);

  const input = document.createElement("input");
  document.body.appendChild(input);
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "z", ctrlKey: true, bubbles: true }));
  expect(pushes(hook, "calendar:undo")).toEqual([{}]);
});

test("a payload arriving while a block is focused keeps focus on it, and one tab stop", () => {
  const { el, handlers } = mountHook();
  block(el, "event-2").focus();

  handlers["calendar:events"](payload());

  expect(document.activeElement.dataset.eventId).toBe("event-2");
  expect(el.querySelectorAll('.cal-ev[tabindex="0"]')).toHaveLength(1);
});

test("when the focused event leaves the grid the first block becomes the one tab stop", () => {
  const { el, handlers } = mountHook();
  block(el, "event-2").focus();

  handlers["calendar:events"](payload({ events: [event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00"), event("event-3", "Lunch", "2026-10-15T12:00", "2026-10-15T13:00")] }));

  expect([...el.querySelectorAll('.cal-ev[tabindex="0"]')].map((node) => node.dataset.eventId)).toEqual(["event-1"]);
});

test("the announcements are written as text, and a missing title reads as empty", () => {
  const { el, live } = mountHook(payload({ events: [event("event-1", "<img src=x onerror=alert(1)>", "2026-10-14T11:00", "2026-10-14T12:00"), event("event-2", undefined, "2026-10-14T14:00", "2026-10-14T15:00")] }));
  block(el, "event-1").focus();

  press("m");
  expect(live.querySelector("img")).toBeNull();
  expect(live.textContent).toBe("Moving <img src=x onerror=alert(1)>, Wed 14 Oct, 11:00 to 12:00.");
  press("Escape");

  block(el, "event-2").focus();
  press("m");
  expect(live.textContent).toBe("Moving , Wed 14 Oct, 14:00 to 15:00.");
});

test("the keys are ignored while a drag is live, and Ctrl Z waits for it", () => {
  const { el, hook } = mountHook();
  block(el, "event-1").focus();
  hook.drag = { state: {}, range: {} };

  press("ArrowDown");
  press("m");
  press("Delete");
  document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "z", ctrlKey: true, bubbles: true }));

  expect(document.activeElement.dataset.eventId).toBe("event-1");
  expect(block(el, "event-1").classList.contains("is-moving")).toBe(false);
  expect(hook.pushEventTo).not.toHaveBeenCalled();
  hook.drag = null;
});

test("the sticky top's height is published for the focus scroll margin", () => {
  const height = vi.spyOn(HTMLElement.prototype, "offsetHeight", "get").mockReturnValue(61);
  const { el } = mountHook();
  height.mockRestore();

  expect(el.style.getPropertyValue("--cal-top-h")).toBe("61px");
});

// What LiveView does: a modal appears for the series choice, and its closing
// leaves focus on the body, because the focus trap's saved block is gone.
const modalRound = async (id = "calendar-series-scope", whileOpen = () => {}) => {
  const modal = document.createElement("div");
  modal.id = id;
  document.body.appendChild(modal);
  await Promise.resolve();
  document.activeElement.blur?.();
  whileOpen();
  modal.remove();
  await Promise.resolve();
};

test("after the delete modal closes, focus returns to the affected block", async () => {
  const { el, handlers } = mountHook();
  block(el, "event-2").focus();
  press("Delete");
  await modalRound("calendar-delete-confirm", () => handlers["calendar:events"](payload()));

  expect(document.activeElement.dataset.eventId).toBe("event-2");
});

test("after the series modal closes on a redrawn grid, focus returns to the moved block", async () => {
  const { el, handlers } = mountHook();
  block(el, "event-1").focus();
  press("m");
  press("ArrowDown");
  press("Enter");
  await modalRound("calendar-series-scope", () => handlers["calendar:events"](payload()));

  expect(document.activeElement.dataset.eventId).toBe("event-1");
});

test("a modal that never opens leaves focus alone", async () => {
  const { el } = mountHook();
  block(el, "event-1").focus();
  press("Delete");
  document.activeElement.blur();
  document.body.appendChild(document.createElement("div"));
  await Promise.resolve();

  expect(document.activeElement).toBe(document.body);
});
