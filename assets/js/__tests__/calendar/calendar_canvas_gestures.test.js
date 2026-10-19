/**
 * Tests for swipe and pinch in the CalendarCanvas hook
 * (hooks/calendar_canvas/gestures.js): a sideways swipe over the time grid or
 * the month changes the period, two fingers over the time grid zoom the hours.
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { LONG_PRESS_MS } from "../../calendar/gestures.js";
import { addDays, makeScale } from "../../calendar/time.js";
import { block, mountHook, payload, pushes, touch, unmountAll } from "./canvas_harness.js";

const hour = (el) => Number(el.querySelector(".cal-grid").getAttribute("style").match(/--cal-hour:(\d+)px/)[1]);
const scroller = (el) => el.querySelector("[data-scroll]");
const month = () => payload({ view: "month", range: { from: "2026-08-31", to: "2026-12-07" } });
const agenda = () => payload({ view: "agenda", range: { from: "2026-09-16", to: "2026-12-08" } });

// One finger from `from` to `to` over `ms` milliseconds, starting on `target`.
function swipe(el, target, from, to, ms = 200) {
  touch(target, "pointerdown", from);
  vi.advanceTimersByTime(ms / 2);
  touch(el, "pointermove", { x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 });
  vi.advanceTimersByTime(ms / 2);
  touch(el, "pointermove", to);
  touch(el, "pointerup", to);
}

beforeEach(() => {
  vi.useFakeTimers();
});

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  document.documentElement.classList.remove("cal-sheet-open");
});

describe("swipe", () => {
  test("a swipe to the left over the week shows the next week", () => {
    const { el, hook } = mountHook();

    swipe(el, scroller(el), { x: 600, y: 300 }, { x: 450, y: 310 });

    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-21" }]);
    expect(hook.date).toBe("2026-10-21");
  });

  test("a swipe to the right shows the previous week", () => {
    const { el, hook } = mountHook();

    swipe(el, scroller(el), { x: 450, y: 300 }, { x: 600, y: 300 });

    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-07" }]);
  });

  test("in Day view a swipe steps one day", () => {
    const { el, hook } = mountHook(payload({ view: "day" }));

    swipe(el, scroller(el), { x: 600, y: 300 }, { x: 450, y: 300 });

    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-15" }]);
  });

  test("two swipes in a row step twice before the server answers", () => {
    const { el, hook } = mountHook();

    swipe(el, scroller(el), { x: 600, y: 300 }, { x: 450, y: 300 });
    swipe(el, scroller(el), { x: 600, y: 300 }, { x: 450, y: 300 });

    expect(pushes(hook, "calendar:goto")).toEqual([
      { view: "week", date: "2026-10-21" },
      { view: "week", date: "2026-10-28" },
    ]);
  });

  test("a slow drag sideways leaves the period alone", () => {
    const { el, hook } = mountHook();

    swipe(el, scroller(el), { x: 600, y: 300 }, { x: 450, y: 300 }, 800);

    expect(pushes(hook, "calendar:goto")).toEqual([]);
    expect(hook.date).toBe("2026-10-14");
  });

  test("a mostly vertical move is a scroll, not a swipe", () => {
    const { el, hook } = mountHook();

    swipe(el, scroller(el), { x: 600, y: 300 }, { x: 520, y: 420 });

    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("the grid follows the finger, and springs back from a short swipe", () => {
    const { el, hook } = mountHook();

    touch(scroller(el), "pointerdown", { x: 600, y: 300 });
    touch(el, "pointermove", { x: 560, y: 300 });
    const drawn = el.firstElementChild;
    const offset = parseFloat(drawn.style.getPropertyValue("--cal-swipe-x"));
    expect(drawn.classList.contains("cal-swiping")).toBe(true);
    expect(offset).toBeLessThan(0);
    expect(offset).toBeGreaterThan(-40);

    touch(el, "pointerup", { x: 560, y: 300 });

    expect(drawn.classList.contains("cal-swiping")).toBe(false);
    expect(drawn.style.getPropertyValue("--cal-swipe-x")).toBe("");
    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("a mouse dragged sideways does not swipe", () => {
    const { el, hook } = mountHook();
    const mouse = (target, type, x) => {
      const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: 300, button: 0 });
      Object.defineProperty(e, "pointerType", { value: "mouse" });
      Object.defineProperty(e, "pointerId", { value: 1 });
      Object.defineProperty(e, "buttons", { value: type === "pointerup" ? 0 : 1 });
      target.dispatchEvent(e);
    };

    mouse(scroller(el), "pointerdown", 600);
    mouse(el, "pointermove", 520);
    mouse(el, "pointermove", 450);
    mouse(el, "pointerup", 450);

    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("a swipe over the month shows the next month", () => {
    const { el, hook } = mountHook(month());

    swipe(el, el.querySelector('[data-month-day="2026-10-21"]'), { x: 600, y: 300 }, { x: 450, y: 300 });

    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "month", date: "2026-11-14" }]);
  });

  test("the agenda does not swipe", () => {
    const { el, hook } = mountHook(agenda());

    swipe(el, el.firstElementChild ?? el, { x: 600, y: 300 }, { x: 450, y: 300 });

    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("once a long-press has picked up an event, moving sideways drags it and leaves the period alone", () => {
    const { el, hook } = mountHook();
    const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
    hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });

    touch(block(el, "event-1"), "pointerdown", { x: 250, y: 582 });
    vi.advanceTimersByTime(LONG_PRESS_MS);
    touch(el, "pointermove", { x: 350, y: 582 });
    touch(el, "pointerup", { x: 350, y: 582 });

    expect(pushes(hook, "calendar:goto")).toEqual([]);
    expect(pushes(hook, "calendar:move")).toHaveLength(1);
  });

  test("while a sheet is open a swipe changes nothing", () => {
    const { el, hook } = mountHook();
    document.documentElement.classList.add("cal-sheet-open");

    swipe(el, scroller(el), { x: 600, y: 300 }, { x: 450, y: 300 });

    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });
});

describe("pinch", () => {
  test("spreading two fingers over the grid makes the hours taller", () => {
    const { el } = mountHook();

    touch(scroller(el), "pointerdown", { x: 300, y: 300, pointerId: 1 });
    touch(scroller(el), "pointerdown", { x: 300, y: 400, pointerId: 2 });
    touch(el, "pointermove", { x: 300, y: 450, pointerId: 2 });

    expect(hour(el)).toBe(78);
  });

  test("closing them makes the hours shorter, but not below the smallest", () => {
    const { el } = mountHook();

    touch(scroller(el), "pointerdown", { x: 300, y: 300, pointerId: 1 });
    touch(scroller(el), "pointerdown", { x: 300, y: 400, pointerId: 2 });
    touch(el, "pointermove", { x: 300, y: 310, pointerId: 2 });

    expect(hour(el)).toBe(24);
  });

  test("the page does not scroll or zoom while two fingers pinch", () => {
    const { el } = mountHook();
    const scroll = () => {
      const move = new Event("touchmove", { bubbles: true, cancelable: true });
      el.dispatchEvent(move);
      return move.defaultPrevented;
    };

    touch(scroller(el), "pointerdown", { x: 300, y: 300, pointerId: 1 });
    expect(scroll()).toBe(false);
    touch(scroller(el), "pointerdown", { x: 300, y: 400, pointerId: 2 });
    expect(scroll()).toBe(true);
  });

  test("a second finger stops a swipe", () => {
    const { el, hook } = mountHook();

    touch(scroller(el), "pointerdown", { x: 600, y: 300, pointerId: 1 });
    touch(el, "pointermove", { x: 500, y: 300, pointerId: 1 });
    touch(scroller(el), "pointerdown", { x: 600, y: 400, pointerId: 2 });

    expect(el.firstElementChild.classList.contains("cal-swiping")).toBe(false);
    touch(el, "pointerup", { x: 450, y: 300, pointerId: 1 });
    touch(el, "pointerup", { x: 600, y: 400, pointerId: 2 });
    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("a pinch over the month leaves the hours alone", () => {
    const { el, hook } = mountHook(month());

    touch(el.firstElementChild, "pointerdown", { x: 300, y: 300, pointerId: 1 });
    touch(el.firstElementChild, "pointerdown", { x: 300, y: 400, pointerId: 2 });
    touch(el, "pointermove", { x: 300, y: 450, pointerId: 2 });

    expect(hook.zoomHour).toBeNull();
  });
});

describe("gesture styles", () => {
  const touchCss = readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../../../css/components/calendar-touch.css"), "utf8");

  test("the grid leaves sideways swipes and pinches to the hook", () => {
    expect(touchCss).toMatch(/\.cal-scroll\s*\{[^}]*touch-action:\s*pan-y/);
  });

  test("so does every part of the month", () => {
    expect(touchCss).toMatch(/\.cal-canvas:has\(\[data-month-day\]\) \*\s*\{[^}]*touch-action:\s*pan-y/);
  });

  test("reduced motion drops the follow", () => {
    expect(touchCss).toMatch(/prefers-reduced-motion:\s*reduce\)\s*\{\s*\.cal-swiping\s*\{[^}]*transform:\s*none/);
  });
});
