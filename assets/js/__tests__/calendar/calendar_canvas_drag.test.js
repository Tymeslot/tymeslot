/**
 * Tests for dragging in the CalendarCanvas hook (hooks/calendar_canvas/drag.js):
 * a drag moves or resizes the block under the pointer, sends nothing until
 * the drop, then asks the server to make it so; a click still opens.
 */
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { addDays, makeScale } from "../../calendar/time.js";
import { block, event, mountHook, payload, pushes, settings, unmountAll } from "./canvas_harness.js";

const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));

// Columns 100px wide from x = 0; the day starts at y = 0 with 52px an hour.
function withGeometry(hook) {
  hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  return hook;
}

// A pointer event as the browser sends it: jsdom has no PointerEvent, so the
// pointer's id and held buttons ride on a mouse event. A press and a move
// hold the primary button, a release does not.
function pointer(type, target, x, y, extra = {}) {
  const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });
  Object.defineProperty(e, "pointerId", { value: extra.pointerId ?? 1 });
  Object.defineProperty(e, "buttons", { value: extra.buttons ?? (type === "pointerup" ? 0 : 1) });
  return target.dispatchEvent(e);
}

const press = (hook, el, id = "event-1") => ({ el, hook, target: block(el, id) });

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

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
  const readOnly = payload({ events: [event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00", { editable: false, movable: false })] });
  const { el, hook } = mountHook(readOnly);
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 350, 634);
  pointer("pointerup", el, 350, 634);

  expect(pushes(hook, "calendar:move")).toEqual([]);
});

test("the calendar copy of a booking does not drag", () => {
  const copy = payload({ events: [event("event-1", "Booked call", "2026-10-14T11:00", "2026-10-14T12:00", { editable: true, movable: false })] });
  const { el, hook } = mountHook(copy);
  withGeometry(hook);

  expect(block(el, "event-1").hasAttribute("data-editable")).toBe(false);
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
  handlers["calendar:events"](payload({ events: [event("event-1", "Renamed by the server", "2026-10-14T11:00", "2026-10-14T12:00")] }));

  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(true);
  expect(block(el, "event-1").textContent).not.toContain("Renamed");

  pointer("pointerup", el, 350, 634);
  handlers["calendar:events"](payload({ events: [event("event-1", "Renamed by the server", "2026-10-15T12:00", "2026-10-15T13:00")] }));

  expect(el.querySelectorAll('[data-event-id="event-1"]').length).toBe(1);
  expect(block(el, "event-1").textContent).toContain("Renamed by the server");
  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(false);
});

function drop(hook, el) {
  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 260, 592);
  pointer("pointermove", el, 350, 634);
  pointer("pointerup", el, 350, 634);
}

test("the server confirming the move leaves one block at the new time", () => {
  const { el, hook, handlers } = mountHook();
  withGeometry(hook);
  drop(hook, el);

  handlers["calendar:events"](payload({ events: [event("event-1", "Design review", "2026-10-15T12:00", "2026-10-15T13:00")] }));

  expect(el.querySelectorAll('[data-event-id="event-1"]').length).toBe(1);
  expect(block(el, "event-1").closest("[data-day]").dataset.day).toBe("2026-10-15");
  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(false);
});

test("the server refusing the move puts the block back at its original time", () => {
  const { el, hook, handlers } = mountHook();
  withGeometry(hook);
  drop(hook, el);
  expect(block(el, "event-1").closest("[data-day]").dataset.day).toBe("2026-10-15");

  handlers["calendar:events"](payload());

  expect(el.querySelectorAll('[data-event-id="event-1"]').length).toBe(1);
  expect(block(el, "event-1").closest("[data-day]").dataset.day).toBe("2026-10-14");
});

test("a pointercancel mid-drag puts the event back and sends nothing", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 350, 634);
  pointer("pointercancel", el, 350, 634);

  expect(pushes(hook, "calendar:move")).toEqual([]);
  expect(block(el, "event-1").closest("[data-day]").dataset.day).toBe("2026-10-14");
  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(false);
});

test("a move with no button held ends the drag, so a later press cannot drop it", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 260, 592);
  pointer("pointermove", el, 350, 634, { buttons: 0 });
  pointer("pointerdown", el, 350, 634);
  pointer("pointerup", el, 350, 634);

  expect(pushes(hook, "calendar:move")).toEqual([]);
  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(false);
});

test("a context menu or a lost pointer capture cancels the drag", () => {
  for (const name of ["contextmenu", "lostpointercapture"]) {
    const { el, hook } = mountHook();
    withGeometry(hook);

    pointer("pointerdown", block(el, "event-1"), 250, 582);
    pointer("pointermove", el, 350, 634);
    el.dispatchEvent(new Event(name, { bubbles: true }));
    pointer("pointerup", el, 350, 634);

    expect(pushes(hook, "calendar:move")).toEqual([]);
    expect(block(el, "event-1").closest("[data-day]").dataset.day).toBe("2026-10-14");
    unmountAll();
  }
});

test("a second pointer can neither take over nor end the drag", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 260, 592);
  pointer("pointerdown", block(el, "event-2"), 250, 842, { pointerId: 2 });
  pointer("pointermove", el, 50, 100, { pointerId: 2 });
  pointer("pointerup", el, 50, 100, { pointerId: 2 });
  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(true);

  pointer("pointermove", el, 350, 634);
  pointer("pointerup", el, 350, 634);

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-15T12:00", end: "2026-10-15T13:00" }]);
});

test("the start grip moves the start and keeps the end", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1").querySelector('[data-grip="start"]'), 250, 572);
  pointer("pointermove", el, 250, 560);
  pointer("pointermove", el, 250, 546);
  pointer("pointerup", el, 250, 546);

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-14T10:30", end: "2026-10-14T12:00" }]);
});

test("resizing to the end of the day reads 00:00", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1").querySelector('[data-grip="end"]'), 250, 624);
  pointer("pointermove", el, 250, 700);
  pointer("pointermove", el, 250, 2000);

  expect(block(el, "event-1").querySelector(".cal-drag-time").textContent).toBe("11:00–00:00");
});

test("with the night folded, a drag cannot reach into it", () => {
  const folded = payload({ settings: { ...settings, fold_night: true } });
  const { el, hook } = mountHook(folded);
  const scale = makeScale(52, true);
  hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale });

  pointer("pointerdown", block(el, "event-1"), 250, scale.yOf(660) + 5);
  pointer("pointermove", el, 250, scale.yOf(660) - 30);
  pointer("pointermove", el, 250, 0);
  pointer("pointerup", el, 250, 0);

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-14T07:00", end: "2026-10-14T08:00" }]);
});

test("a scroll mid-drag keeps the block under the pointer", () => {
  const { el, hook } = mountHook();
  let top = 0;
  hook.gridGeometry = () => ({ left: 0, top, colWidth: 100, days, scale: makeScale(52, false) });

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 250, 600);
  top = -104; // two hours scrolled; the pointer has not moved
  el.querySelector("[data-scroll]").dispatchEvent(new Event("scroll"));
  expect(block(el, "event-1").querySelector(".cal-drag-time").textContent).toBe("13:15–14:15");
  pointer("pointerup", el, 250, 600);

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-14T13:15", end: "2026-10-14T14:15" }]);
});

test("the columns' position is read afresh on every move", () => {
  const { el, hook } = mountHook();
  let top = 0;
  hook.gridGeometry = () => ({ left: 0, top, colWidth: 100, days, scale: makeScale(52, false) });

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 250, 600);
  top = -104;
  pointer("pointermove", el, 250, 582);
  pointer("pointerup", el, 250, 582);

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-14T13:00", end: "2026-10-14T14:00" }]);
});

// Stubs a scroller 600px tall inside which the headings sit on top: they end at y = 60.
function scrollRig(el) {
  const frames = [];
  const cancelled = vi.fn();
  vi.stubGlobal("requestAnimationFrame", (callback) => frames.push(callback));
  vi.stubGlobal("cancelAnimationFrame", cancelled);
  const scroller = el.querySelector("[data-scroll]");
  let scrollTop = 0;
  Object.defineProperty(scroller, "scrollTop", { get: () => scrollTop, set: (v) => (scrollTop = v), configurable: true });
  Object.defineProperty(scroller, "scrollHeight", { value: 1000, configurable: true });
  Object.defineProperty(scroller, "clientHeight", { value: 600, configurable: true });
  scroller.getBoundingClientRect = () => ({ top: 0, bottom: 600, left: 0, right: 900 });
  el.querySelector(".cal-top").getBoundingClientRect = () => ({ top: 0, bottom: 60, left: 0, right: 900 });
  return { scroll: () => scrollTop, set: (v) => (scrollTop = v), run: () => frames.splice(0).forEach((frame) => frame()), frames, cancelled };
}

test("near the scroller's bottom edge the grid scrolls, within its range", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  const rig = scrollRig(el);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 250, 590);
  pointer("pointermove", el, 250, 598);
  rig.run();
  expect(rig.scroll()).toBeGreaterThan(0);

  for (let i = 0; i < 100; i += 1) rig.run();
  expect(rig.scroll()).toBe(400); // clamped to scrollHeight - clientHeight
});

test("the top zone starts below the sticky headings, not at the scroller's top", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  const rig = scrollRig(el);
  rig.set(200);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 250, 400);
  pointer("pointermove", el, 250, 30); // over the middle of the headings
  rig.run();
  expect(rig.scroll()).toBe(200);

  pointer("pointermove", el, 250, 70); // just below them
  rig.run();
  expect(rig.scroll()).toBeLessThan(200);
});

test("a drop or a destroy mid-scroll stops the scrolling", () => {
  for (const end of ["drop", "destroy"]) {
    const { el, hook } = mountHook();
    withGeometry(hook);
    const rig = scrollRig(el);

    pointer("pointerdown", block(el, "event-1"), 250, 582);
    pointer("pointermove", el, 250, 590);
    pointer("pointermove", el, 250, 598);
    rig.run();
    const before = rig.scroll();
    expect(before).toBeGreaterThan(0);
    expect(before).toBeLessThan(400);

    if (end === "drop") pointer("pointerup", el, 250, 598);
    else hook.destroyDrag();
    expect(rig.cancelled).toHaveBeenCalled();
    rig.run();
    expect(rig.scroll()).toBe(before);
    expect(hook.drag).toBeNull();
    expect(hook.press).toBeNull();
    unmountAll();
  }
});

test("a new pointer replaces a press that never became a drag", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-2"), 250, 842, { pointerId: 2 });
  pointer("pointerdown", block(el, "event-1"), 250, 582, { pointerId: 3 });
  pointer("pointermove", el, 260, 592, { pointerId: 3 });
  pointer("pointermove", el, 350, 634, { pointerId: 3 });
  pointer("pointerup", el, 350, 634, { pointerId: 3 });

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-15T12:00", end: "2026-10-15T13:00" }]);
});

test("the block pressed is found again when opening the drag redrew the grid", () => {
  vi.stubGlobal("CSS", { escape: (text) => text });
  const { el, hook } = mountHook();
  withGeometry(hook);
  hook.list = document.createElement("div");
  document.body.append(hook.list);
  hook.dirty = true;

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 350, 634);

  expect(el.querySelectorAll('.cal-ev[data-event-id="event-1"]').length).toBe(1);
  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(true);
});

test("Escape pressed on the page cancels a live drag and the click after the release is swallowed", () => {
  vi.useFakeTimers();
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 350, 634);
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  expect(block(el, "event-1").classList.contains("is-dragging")).toBe(false);

  // A slow release: the click that ends it is still the drag's.
  vi.advanceTimersByTime(500);
  pointer("pointerup", el, 350, 634);
  block(el, "event-1").click();
  expect(pushes(hook, "calendar:open")).toEqual([]);

  // Gone by the next tick: a later click is a click again.
  vi.advanceTimersByTime(1);
  block(el, "event-1").click();
  expect(pushes(hook, "calendar:open")).toEqual([{ id: "event-1" }]);
});
