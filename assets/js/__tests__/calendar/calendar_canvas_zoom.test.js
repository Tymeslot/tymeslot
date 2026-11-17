/**
 * Tests for Ctrl + scroll zoom in the CalendarCanvas hook
 * (hooks/calendar_canvas/zoom.js).
 */
import { afterEach, expect, test, vi } from "vitest";
import { mountHook, settings, unmountAll } from "./canvas_harness.js";

const wheel = (el, deltaY, extra = {}) => {
  const event = new WheelEvent("wheel", { deltaY, bubbles: true, cancelable: true, ...extra });
  el.dispatchEvent(event);
  return event;
};
const hour = (el) => Number(el.querySelector(".cal-grid").getAttribute("style").match(/--cal-hour:(\d+)px/)[1]);

afterEach(() => {
  vi.restoreAllMocks();
  unmountAll();
});

test("Ctrl + scroll zooms the hours", () => {
  const { el } = mountHook();

  const event = wheel(el, -100, { ctrlKey: true });

  expect(hour(el)).toBe(64);
  expect(event.defaultPrevented).toBe(true);
});

test("plain scrolling leaves the hours alone", () => {
  const { el } = mountHook();

  const event = wheel(el, -100);

  expect(hour(el)).toBe(52);
  expect(event.defaultPrevented).toBe(false);
});

test("the wheel listener is not passive", () => {
  const add = vi.spyOn(HTMLElement.prototype, "addEventListener");
  mountHook();

  const call = add.mock.calls.find(([name]) => name === "wheel");
  expect(call[2]).toEqual({ passive: false });
});

test("Cmd alone does not zoom off macOS", () => {
  const { el } = mountHook();

  const event = wheel(el, -100, { metaKey: true });

  expect(hour(el)).toBe(52);
  expect(event.defaultPrevented).toBe(false);
});

test("a run of small trackpad steps changes the drawn height", () => {
  const { el } = mountHook();

  for (let i = 0; i < 20; i += 1) wheel(el, -2, { ctrlKey: true });

  expect(hour(el)).toBeGreaterThan(52);
});

test("a line-mode wheel counts 16px a line", () => {
  const { el } = mountHook();

  wheel(el, -6, { ctrlKey: true, deltaMode: 1 });

  // -96px, as a pixel wheel of -96 would zoom.
  const other = mountHook();
  wheel(other.el, -96, { ctrlKey: true });
  expect(hour(el)).toBe(hour(other.el));
  expect(hour(el)).toBeGreaterThan(52);
});

test("a page-mode wheel counts the scroller's height", () => {
  const { el } = mountHook();
  Object.defineProperty(el.querySelector("[data-scroll]"), "clientHeight", { value: 100, configurable: true });
  vi.spyOn(HTMLElement.prototype, "clientHeight", "get").mockReturnValue(100);

  wheel(el, -1, { ctrlKey: true, deltaMode: 2 });

  const other = mountHook();
  wheel(other.el, -100, { ctrlKey: true });
  expect(hour(el)).toBe(hour(other.el));
});

test("the time under the pointer stays under the pointer", () => {
  const { el, hook } = mountHook();
  // jsdom has no layout: model one, with the scroller at scrollTop and the
  // columns starting 100px below the top of the viewport minus the scroll.
  let scrollTop = 300;
  vi.spyOn(HTMLElement.prototype, "scrollTop", "get").mockImplementation(() => scrollTop);
  vi.spyOn(HTMLElement.prototype, "scrollTop", "set").mockImplementation((value) => {
    scrollTop = value;
  });
  vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function () {
    const top = this.classList.contains("cal-cols") ? 100 - scrollTop : 0;
    return { top, left: 0, right: 0, bottom: 0, width: 0, height: 0 };
  });
  const pointerY = 400;
  const before = hook.currentScale().minuteOf(pointerY - (100 - scrollTop));

  wheel(el, -100, { ctrlKey: true, clientY: pointerY });

  const after = hook.currentScale().minuteOf(pointerY - (100 - scrollTop));
  expect(hour(el)).toBe(64);
  expect(scrollTop).not.toBe(300);
  expect(Math.abs(after - before)).toBeLessThan(1);
});

test("a live drag is not zoomed under, and the browser does not zoom the page either", () => {
  const { el, hook } = mountHook();
  hook.drag = {};

  const event = wheel(el, -100, { ctrlKey: true });

  expect(hour(el)).toBe(52);
  expect(event.defaultPrevented).toBe(true);
  hook.drag = null;
});

test("plain scrolling during a live drag is left to the browser", () => {
  const { el, hook } = mountHook();
  hook.drag = {};

  const event = wheel(el, -100);

  expect(hour(el)).toBe(52);
  expect(event.defaultPrevented).toBe(false);
  hook.drag = null;
});

test("a density change goes back to the saved height", () => {
  const { el, handlers } = mountHook();
  wheel(el, -100, { ctrlKey: true });

  handlers["calendar:settings"]({ ...settings, density: "compact" });

  expect(hour(el)).toBe(38);
});

test("a settings push that leaves density alone keeps the zoom", () => {
  const { el, handlers } = mountHook();
  wheel(el, -100, { ctrlKey: true });
  const zoomed = hour(el);

  handlers["calendar:settings"]({ ...settings, focus: true });

  expect(hour(el)).toBe(zoomed);
});

test("zoomTo draws the hour height it is given, within the zoom's bounds", () => {
  const { el, hook } = mountHook();

  hook.zoomTo(80, 400);
  expect(hour(el)).toBe(80);

  hook.zoomTo(500, 400);
  expect(hour(el)).toBe(128);

  hook.zoomTo(5, 400);
  expect(hour(el)).toBe(24);
});
