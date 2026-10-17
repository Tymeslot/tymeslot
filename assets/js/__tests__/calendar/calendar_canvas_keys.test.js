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

// A move mode that outlives its block's focus must not catch later keys.
test("tabbing away from a move mode cancels it, so Enter elsewhere is not its save", () => {
  const { el, hook, live } = mountHook();
  block(el, "event-1").focus();
  press("m");
  press("ArrowDown");

  const outside = document.createElement("input");
  document.body.appendChild(outside);
  outside.focus();
  expect(block(el, "event-1").classList.contains("is-moving")).toBe(false);
  expect(live.textContent).toBe("Move cancelled. Design review stays at Wed 14 Oct, 11:00 to 12:00.");

  block(el, "event-2").focus();
  press("Enter");
  expect(pushes(hook, "calendar:move")).toEqual([]);
  expect(pushes(hook, "calendar:open")).toEqual([{ id: "event-2" }]);
});

test("a key on another block cancels the move mode first", () => {
  const { el, hook } = mountHook();
  block(el, "event-1").focus();
  press("m");
  press("ArrowDown");

  block(el, "event-2").focus();
  press("Enter");

  expect(pushes(hook, "calendar:move")).toEqual([]);
  expect(block(el, "event-1").classList.contains("is-moving")).toBe(false);
});

test("a redraw's focus loss does not end the move mode", () => {
  const { el, handlers } = mountHook();
  block(el, "event-1").focus();
  press("m");
  handlers["calendar:events"](payload());

  expect(block(el, "event-1").classList.contains("is-moving")).toBe(true);
});

test("navigating, or opening a preview, ends the move mode", () => {
  const { el, hook } = mountHook();
  block(el, "event-1").focus();
  press("m");

  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21", step: 1 } }));
  expect(hook.moving).toBeNull();
});

test("opening a preview ends the move mode", () => {
  const { el, hook } = mountHook();
  block(el, "event-1").focus();
  press("m");

  hook.open("event-2", block(el, "event-2"));

  expect(hook.moving).toBeNull();
});

test("a drag beginning ends the move mode", () => {
  const { el, hook } = mountHook();
  block(el, "event-1").focus();
  press("m");
  globalThis.CSS ??= { escape: (value) => value };
  hook.press = { event: hook.cache.events.get("event-2"), target: block(el, "event-2"), mode: "move", x: 0, y: 0, slot: { day: 0, minute: 0 } };

  hook.startDrag();

  expect(hook.moving).toBeNull();
  hook.cancelDrag();
});

test("Ctrl Z is left alone while a calendar modal or any dialog is open, or when already handled", () => {
  const { hook } = mountHook();
  const z = (target, extra = {}) => target.dispatchEvent(new KeyboardEvent("keydown", { key: "z", ctrlKey: true, bubbles: true, cancelable: true, ...extra }));

  const dialog = document.createElement("div");
  dialog.setAttribute("role", "dialog");
  const inner = document.createElement("button");
  dialog.appendChild(inner);
  document.body.appendChild(dialog);
  z(inner);
  dialog.remove();

  const modal = document.createElement("div");
  modal.id = "calendar-series-scope";
  document.body.appendChild(modal);
  z(document.body);
  modal.remove();

  const editable = document.createElement("div");
  editable.contentEditable = "true";
  Object.defineProperty(editable, "isContentEditable", { value: true });
  document.body.appendChild(editable);
  z(editable);

  document.body.addEventListener("keydown", (e) => e.preventDefault(), { once: true });
  z(document.body);

  expect(pushes(hook, "calendar:undo")).toEqual([]);

  z(document.body, { key: "Z" });
  expect(pushes(hook, "calendar:undo")).toEqual([{}]);
  document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "я", code: "KeyZ", metaKey: true, bubbles: true }));
  expect(pushes(hook, "calendar:undo")).toEqual([{}, {}]);
});

test("the modal watch outlasts a modal left open for a long time", async () => {
  vi.useFakeTimers();
  try {
    const { el } = mountHook();
    block(el, "event-1").focus();
    press("Delete");
    const modal = document.createElement("div");
    modal.id = "calendar-delete-confirm";
    document.body.appendChild(modal);
    await Promise.resolve();

    vi.advanceTimersByTime(60_000);
    document.activeElement.blur();
    modal.remove();
    await Promise.resolve();

    expect(document.activeElement.dataset.eventId).toBe("event-1");
  } finally {
    vi.useRealTimers();
  }
});

test("the modal watch gives up when no modal appears, and forgets the neighbour", async () => {
  vi.useFakeTimers();
  try {
    const { el, hook } = mountHook();
    block(el, "event-1").focus();
    press("Delete");
    expect(hook.pendingFocus).not.toBeNull();

    vi.advanceTimersByTime(11_000);

    expect(hook.pendingFocus).toBeNull();
    expect(hook.modalWatch).toBeNull();
  } finally {
    vi.useRealTimers();
  }
});

test("a drop and the preview's Delete button also watch for the modal", () => {
  const { el, hook } = mountHook();
  hook.commitMove("event-1", { startMin: hook.cache.events.get("event-1").startMin + 30, endMin: hook.cache.events.get("event-1").endMin + 30 });
  expect(hook.modalWatch).not.toBeNull();
  hook.unwatchModal();

  hook.lastOpened = "event-2";
  const button = document.createElement("button");
  button.id = "calendar-preview-delete";
  document.body.appendChild(button);
  button.click();
  expect(hook.modalWatch).not.toBeNull();
  expect(el).toBeTruthy();
});

test("the move announcement is debounced while a key repeats, and the last position is read", () => {
  vi.useFakeTimers();
  try {
    const { el, live } = mountHook();
    block(el, "event-1").focus();
    press("m");
    press("ArrowDown");
    expect(live.textContent).toBe("Wed 14 Oct, 11:15 to 12:15");

    press("ArrowDown", { repeat: true });
    press("ArrowDown", { repeat: true });
    expect(live.textContent).toBe("Wed 14 Oct, 11:15 to 12:15");

    vi.advanceTimersByTime(400);
    expect(live.textContent).toBe("Wed 14 Oct, 11:45 to 12:45");
  } finally {
    vi.useRealTimers();
  }
});

test("arrows with Alt, Meta or Ctrl are left to the browser", () => {
  const { el } = mountHook();
  block(el, "event-1").focus();
  const event = new KeyboardEvent("keydown", { key: "ArrowLeft", altKey: true, bubbles: true, cancelable: true });
  document.activeElement.dispatchEvent(event);
  expect(event.defaultPrevented).toBe(false);

  press("m");
  const inMove = new KeyboardEvent("keydown", { key: "ArrowLeft", metaKey: true, bubbles: true, cancelable: true });
  document.activeElement.dispatchEvent(inMove);
  expect(inMove.defaultPrevented).toBe(false);
  expect(block(el, "event-1").classList.contains("is-moving")).toBe(true);
});

test("Escape in the move mode does not travel on to close a preview", () => {
  const { el } = mountHook();
  block(el, "event-1").focus();
  press("m");
  const seen = vi.fn();
  document.body.addEventListener("keydown", seen);

  press("Escape");
  document.body.removeEventListener("keydown", seen);

  expect(seen).not.toHaveBeenCalled();
});

test("the scroll container is an application region named for the period", () => {
  const { el } = mountHook();
  const scroller = el.querySelector("[data-scroll]");

  expect(scroller.getAttribute("role")).toBe("application");
  expect(scroller.getAttribute("aria-roledescription")).toBe("calendar");
  expect(scroller.getAttribute("aria-label")).toBe("Mon 12 Oct to Sun 18 Oct");
});

test("a pending repeat announcement is dropped when the move mode ends silently", () => {
  vi.useFakeTimers();
  try {
    const { el, hook, live } = mountHook();
    block(el, "event-1").focus();
    press("m");
    press("ArrowDown");
    press("ArrowDown", { repeat: true });
    const before = live.textContent;

    hook.open("event-2", block(el, "event-2"));
    vi.advanceTimersByTime(1_000);

    expect(live.textContent).toBe(before);
  } finally {
    vi.useRealTimers();
  }
});

test("a payload for another week ends the move mode", () => {
  const { el, handlers, hook } = mountHook();
  block(el, "event-1").focus();
  press("m");

  handlers["calendar:events"](payload({ date: "2026-10-21", range: { from: "2026-10-12", to: "2026-11-02" } }));

  expect(hook.moving).toBeNull();
});

test("destroying the hook clears a pending announcement", () => {
  vi.useFakeTimers();
  try {
    const { el, hook, live } = mountHook();
    block(el, "event-1").focus();
    press("m");
    press("ArrowDown");
    press("ArrowDown", { repeat: true });
    const before = live.textContent;

    hook.destroyed();
    vi.advanceTimersByTime(1_000);

    expect(live.textContent).toBe(before);
  } finally {
    vi.useRealTimers();
  }
});
