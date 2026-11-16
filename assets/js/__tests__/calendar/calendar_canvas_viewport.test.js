/**
 * The hook's viewport (hooks/calendar_canvas/viewport.js): it tells the
 * server whether a phone is asking, reports a width that crosses the phone
 * boundary once it has settled, and draws a week as three days on a phone.
 */
import { afterEach, expect, test, vi } from "vitest";
import { VIEWPORT_DEBOUNCE_MS } from "../../hooks/calendar_canvas/viewport.js";
import { mockViewport, mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

afterEach(() => {
  vi.useRealTimers();
  unmountAll();
});

const columns = (el) => [...el.querySelectorAll(".cal-col")].map((column) => column.dataset.day);

test("the first request tells the server a phone is asking", () => {
  mockViewport(true);
  const { readyParams } = mountHook();
  expect(readyParams.phone).toBe(true);
});

test("a wide screen, or a browser without matchMedia, asks as wide", () => {
  mockViewport(false);
  expect(mountHook().readyParams.phone).toBe(false);
  unmountAll();
  expect(mountHook().readyParams.phone).toBe(false);
});

test("crossing the boundary is reported once it settles", () => {
  vi.useFakeTimers();
  const media = mockViewport(false);
  const { hook } = mountHook();

  media.set(true);
  media.set(false);
  media.set(true);
  vi.advanceTimersByTime(VIEWPORT_DEBOUNCE_MS - 1);
  expect(pushes(hook, "calendar:viewport")).toEqual([]);

  vi.advanceTimersByTime(1);
  expect(pushes(hook, "calendar:viewport")).toEqual([{ phone: true }]);
});

test("a change that ends where it started is not reported", () => {
  vi.useFakeTimers();
  const media = mockViewport(false);
  const { hook } = mountHook();

  media.set(true);
  media.set(false);
  vi.advanceTimersByTime(VIEWPORT_DEBOUNCE_MS);

  expect(pushes(hook, "calendar:viewport")).toEqual([]);
});

test("on a phone, a week asked for is drawn as three days", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ view: "three_day" }));

  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-12" } }));

  expect(columns(el)).toEqual(["2026-10-12", "2026-10-13", "2026-10-14"]);
});

test("on a wide screen, a week stays a week", () => {
  mockViewport(false);
  const { el } = mountHook(payload({ view: "three_day" }));

  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-12" } }));

  expect(columns(el)).toHaveLength(7);
});

test("a week on screen becomes three days as soon as the width turns to a phone", () => {
  vi.useFakeTimers();
  const media = mockViewport(false);
  const { el } = mountHook();
  expect(columns(el)).toHaveLength(7);

  media.set(true);
  vi.advanceTimersByTime(VIEWPORT_DEBOUNCE_MS);

  expect(columns(el)).toEqual(["2026-10-14", "2026-10-15", "2026-10-16"]);
});

test("unmounting stops listening", () => {
  const media = mockViewport(false);
  mountHook();
  expect(media.listeners.size).toBe(1);

  unmountAll();

  expect(media.listeners.size).toBe(0);
});
