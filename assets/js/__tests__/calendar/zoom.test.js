/**
 * Tests for Ctrl + scroll zoom (calendar/zoom.js).
 */
import { expect, test } from "vitest";
import { MAX_HOUR, MIN_HOUR, wheelPixels, zoomedHour } from "../../calendar/zoom.js";

test("scrolling up zooms in and down zooms out", () => {
  expect(Math.round(zoomedHour(52, -100))).toBe(64);
  expect(Math.round(zoomedHour(52, 100))).toBe(43);
});

test("stays between the smallest and the largest hour", () => {
  expect(zoomedHour(120, -1000)).toBe(MAX_HOUR);
  expect(zoomedHour(30, 1000)).toBe(MIN_HOUR);
});

test("keeps the fraction, so small steps add up", () => {
  const once = zoomedHour(60, -2);
  expect(once).toBeGreaterThan(60);
  expect(once).not.toBe(Math.round(once));
  let height = 60;
  for (let i = 0; i < 20; i += 1) height = zoomedHour(height, -2);
  expect(Math.round(height)).toBeGreaterThan(60);
});

test("wheel deltas are brought to pixels", () => {
  expect(wheelPixels(10, 0, 500)).toBe(10);
  expect(wheelPixels(3, 1, 500)).toBe(48);
  expect(wheelPixels(1, 2, 500)).toBe(500);
});
