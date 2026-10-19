/**
 * Tests for touch in the CalendarCanvas hook (hooks/calendar_canvas/touch_drag.js):
 * a long-press drags an event and a scroll, a lift or a second finger does
 * not; a tapped event is selected on touch screens, and its handle resizes it.
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { LONG_PRESS_MS } from "../../calendar/gestures.js";
import { addDays, makeScale } from "../../calendar/time.js";
import { COARSE_QUERY, PHONE_QUERY } from "../../calendar/viewport.js";
import { block, event, mountHook, payload, pushes, touch, unmountAll } from "./canvas_harness.js";

const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));

// matchMedia as a phone or a desktop, with a finger or a mouse, answers it.
function stubMedia({ phone = false, coarse = false } = {}) {
  vi.stubGlobal("matchMedia", (query) => ({
    matches: (query === PHONE_QUERY && phone) || (query === COARSE_QUERY && coarse),
    media: query,
    addEventListener() {},
    removeEventListener() {},
    addListener() {},
    removeListener() {},
  }));
}

// Columns 100px wide from x = 0; the day starts at y = 0 with 52px an hour,
// so "Design review" (Wed 11:00 to 12:00) spans x 200 to 300, y 572 to 624.
function mount(first = payload()) {
  const mounted = mountHook(first);
  mounted.hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  return mounted;
}

const dragging = (el) => !!block(el, "event-1")?.classList.contains("is-dragging");
const handle = (el) => el.querySelector("[data-touch-handle]");

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe("long-press", () => {
  test("a finger resting on an event picks it up, and moving it drags the event there", () => {
    stubMedia({ phone: true, coarse: true });
    const { el, hook } = mount();

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    vi.advanceTimersByTime(LONG_PRESS_MS);
    expect(dragging(el)).toBe(true);

    touch(el, "pointermove", { x: 350, y: 634 });
    touch(el, "pointerup", { x: 350, y: 634 });

    expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-15T12:00", end: "2026-10-15T13:00" }]);
  });

  test("before the long-press the event only shows it is being pressed", () => {
    stubMedia({ coarse: true });
    const { el } = mount();

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    vi.advanceTimersByTime(LONG_PRESS_MS - 1);

    expect(dragging(el)).toBe(false);
    expect(block(el, "event-1").classList.contains("is-pressing")).toBe(true);
  });

  test("a finger that moves before the long-press is a scroll, not a drag", () => {
    stubMedia({ coarse: true });
    const { el, hook } = mount();

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    touch(el, "pointermove", { x: 250, y: 600 });
    vi.advanceTimersByTime(LONG_PRESS_MS);

    expect(dragging(el)).toBe(false);
    expect(block(el, "event-1").classList.contains("is-pressing")).toBe(false);
    expect(pushes(hook, "calendar:move")).toEqual([]);
  });

  test("a lift before the long-press leaves the tap to open the event", () => {
    stubMedia({ coarse: true });
    const { el, hook } = mount();

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    vi.advanceTimersByTime(200);
    touch(block(el, "event-1"), "pointerup", { x: 250, y: 582 });
    vi.advanceTimersByTime(LONG_PRESS_MS);
    block(el, "event-1").click();

    expect(dragging(el)).toBe(false);
    expect(pushes(hook, "calendar:open")).toEqual([{ id: "event-1" }]);
  });

  test("a second finger cancels the long-press", () => {
    stubMedia({ coarse: true });
    const { el } = mount();

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    touch(el.querySelector("[data-scroll]"), "pointerdown", { x: 500, y: 300, pointerId: 2 });
    vi.advanceTimersByTime(LONG_PRESS_MS);

    expect(dragging(el)).toBe(false);
  });

  test("the grid scrolling cancels the long-press", () => {
    stubMedia({ coarse: true });
    const { el } = mount();

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    el.querySelector("[data-scroll]").dispatchEvent(new Event("scroll"));
    vi.advanceTimersByTime(LONG_PRESS_MS);

    expect(dragging(el)).toBe(false);
  });

  test("an event that cannot move is never picked up", () => {
    stubMedia({ coarse: true });
    const fixed = event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00", { editable: false, movable: false });
    const { el } = mount(payload({ events: [fixed] }));

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    vi.advanceTimersByTime(LONG_PRESS_MS);

    expect(dragging(el)).toBe(false);
  });

  test("a mouse held still is not a long-press", () => {
    const { el } = mount();
    const press = new MouseEvent("pointerdown", { bubbles: true, cancelable: true, clientX: 250, clientY: 582, button: 0 });
    Object.defineProperty(press, "pointerType", { value: "mouse" });
    Object.defineProperty(press, "pointerId", { value: 1 });

    block(el, "event-1").dispatchEvent(press);
    vi.advanceTimersByTime(LONG_PRESS_MS);

    expect(dragging(el)).toBe(false);
  });

  test("the page does not scroll under a live touch drag, and only then", () => {
    stubMedia({ coarse: true });
    const { el } = mount();
    const scroll = () => {
      const move = new Event("touchmove", { bubbles: true, cancelable: true });
      block(el, "event-1").dispatchEvent(move);
      return move.defaultPrevented;
    };

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    expect(scroll()).toBe(false);
    vi.advanceTimersByTime(LONG_PRESS_MS);
    expect(scroll()).toBe(true);
  });

  test("the context menu a long-press raises neither shows nor cancels the drag", () => {
    stubMedia({ coarse: true });
    const { el, hook } = mount();

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    vi.advanceTimersByTime(LONG_PRESS_MS);
    const menu = new MouseEvent("contextmenu", { bubbles: true, cancelable: true });
    block(el, "event-1").dispatchEvent(menu);

    expect(menu.defaultPrevented).toBe(true);
    expect(hook.drag).not.toBeNull();
  });

  test("the capture moving from the block to the canvas does not cancel the drag", () => {
    stubMedia({ coarse: true });
    const { el, hook } = mount();

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    vi.advanceTimersByTime(LONG_PRESS_MS);
    block(el, "event-1").dispatchEvent(new Event("lostpointercapture", { bubbles: true }));
    touch(el, "pointermove", { x: 350, y: 634 });
    touch(el, "pointerup", { x: 350, y: 634 });

    expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-15T12:00", end: "2026-10-15T13:00" }]);
  });
});

describe("selection and the resize handle", () => {
  test("tapping an event on a touch screen selects it and puts a handle under its bottom edge", () => {
    stubMedia({ phone: true, coarse: true });
    const { el } = mount();

    block(el, "event-1").click();

    const target = block(el, "event-1");
    expect(target.classList.contains("is-selected")).toBe(true);
    expect(handle(el).dataset.touchHandle).toBe("event-1");
    expect(handle(el).closest(".cal-ev")).toBeNull();
    expect(parseFloat(handle(el).style.top)).toBe(parseFloat(target.style.top) + parseFloat(target.style.height));
  });

  test("with a mouse, opening an event selects nothing", () => {
    stubMedia({ coarse: false });
    const { el } = mount();

    block(el, "event-1").click();

    expect(block(el, "event-1").classList.contains("is-selected")).toBe(false);
    expect(handle(el)).toBeNull();
  });

  test("an event that cannot be resized is selected without a handle", () => {
    stubMedia({ coarse: true });
    const fixed = event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00", { editable: false, movable: false });
    const { el } = mount(payload({ events: [fixed] }));

    block(el, "event-1").click();

    expect(block(el, "event-1").classList.contains("is-selected")).toBe(true);
    expect(handle(el)).toBeNull();
  });

  test("the selection stays through a redraw and the preview closing", () => {
    stubMedia({ coarse: true });
    const { el, hook, handlers } = mount();

    block(el, "event-1").click();
    hook.render();
    handlers["calendar:preview-closed"]();

    expect(block(el, "event-1").classList.contains("is-selected")).toBe(true);
    expect(handle(el)).not.toBeNull();
  });

  test("Escape lets go of the selection", () => {
    stubMedia({ coarse: true });
    const { el } = mount();

    block(el, "event-1").click();
    el.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));

    expect(block(el, "event-1").classList.contains("is-selected")).toBe(false);
    expect(handle(el)).toBeNull();
  });

  test("a tap on the empty grid lets go of the selection without dropping a draft", () => {
    stubMedia({ coarse: true });
    const { el, hook } = mount();

    block(el, "event-1").click();
    el.querySelector('.cal-col[data-day="2026-10-16"]').dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: 450, clientY: 520 }));

    expect(block(el, "event-1").classList.contains("is-selected")).toBe(false);
    expect(hook.draft).toBeFalsy();
  });

  test("dragging the handle resizes the end, which follows the edge rather than the finger", () => {
    stubMedia({ phone: true, coarse: true });
    const { el, hook } = mount();

    block(el, "event-1").click();
    // The edge is at y 624 (12:00); the finger lands on the handle 22px below it.
    touch(handle(el), "pointerdown", { x: 250, y: 646 });
    touch(el, "pointermove", { x: 250, y: 672 });
    touch(el, "pointerup", { x: 250, y: 672 });

    expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-14T11:00", end: "2026-10-14T12:30" }]);
    expect(handle(el).dataset.touchHandle).toBe("event-1");
  });
});

describe("touch styles", () => {
  const css = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css");
  const touchCss = readFileSync(resolve(css, "components/calendar-touch.css"), "utf8");

  test("the stylesheet is loaded", () => {
    expect(readFileSync(resolve(css, "app.css"), "utf8")).toContain('@import "./components/calendar-touch.css";');
  });

  test("a press on the handle is never a scroll", () => {
    expect(touchCss).toMatch(/\[data-touch-handle\]\s*\{[^}]*touch-action:\s*none/);
  });

  test("a long press on an event never opens the iOS callout", () => {
    expect(touchCss).toMatch(/\.cal-ev\s*\{[^}]*-webkit-touch-callout:\s*none/);
  });
});
