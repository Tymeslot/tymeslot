/**
 * Tests for dragging in the CalendarCanvas hook (hooks/calendar_canvas/drag.js):
 * a drag moves or resizes the block under the pointer, sends nothing until
 * the drop, then asks the server to make it so; a click still opens.
 */
import { afterEach, expect, test } from "vitest";
import { addDays, makeScale } from "../../calendar/time.js";
import { block, event, mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));

// Columns 100px wide from x = 0; the day starts at y = 0 with 52px an hour.
function withGeometry(hook) {
  hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  return hook;
}

const pointer = (type, target, x, y) =>
  target.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 }));

afterEach(unmountAll);

test("dragging to another day and time asks the server to move the event there", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 260, 592);
  pointer("pointermove", el, 350, 634);
  pointer("pointerup", el, 350, 634);

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-15T12:00", end: "2026-10-15T13:00" }]);
  expect(block(el, "event-1").closest("[data-day]").dataset.day).toBe("2026-10-15");
});

test("while dragging, the block shows its new time and nothing is sent", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 260, 592);
  pointer("pointermove", el, 250, 634);

  const dragged = block(el, "event-1");
  expect(dragged.classList.contains("is-dragging")).toBe(true);
  expect(dragged.querySelector(".cal-drag-time").textContent).toBe("12:00–13:00");
  expect(pushes(hook, "calendar:move")).toEqual([]);
});

test("the bottom edge resizes the event", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1").querySelector('[data-grip="end"]'), 250, 624);
  pointer("pointermove", el, 250, 640);
  pointer("pointermove", el, 250, 650);
  pointer("pointerup", el, 250, 650);

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-14T11:00", end: "2026-10-14T12:30" }]);
});

test("a click without a drag still opens the event", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  const target = block(el, "event-1");

  pointer("pointerdown", target, 250, 582);
  pointer("pointerup", target, 250, 582);
  target.click();

  expect(pushes(hook, "calendar:open")).toEqual([{ id: "event-1" }]);
  expect(pushes(hook, "calendar:move")).toEqual([]);
});

test("a drop where the drag started sends nothing, and swallows the click", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 250, 600);
  pointer("pointermove", el, 250, 582);
  pointer("pointerup", el, 250, 582);
  el.click();

  expect(pushes(hook, "calendar:move")).toEqual([]);
  expect(pushes(hook, "calendar:open")).toEqual([]);
});

test("Escape during a drag puts the event back", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 350, 634);
  el.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  pointer("pointerup", el, 350, 634);

  expect(pushes(hook, "calendar:move")).toEqual([]);
  expect(block(el, "event-1").closest("[data-day]").dataset.day).toBe("2026-10-14");
  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(false);
});

test("an event the organiser cannot change does not drag", () => {
  const readOnly = payload({ events: [event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00", { editable: false })] });
  const { el, hook } = mountHook(readOnly);
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 350, 634);
  pointer("pointerup", el, 350, 634);

  expect(pushes(hook, "calendar:move")).toEqual([]);
});

test("a payload arriving mid-drag waits for the drop", () => {
  const { el, hook, handlers } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 350, 634);
  handlers["calendar:events"](payload());

  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(true);
});
