/**
 * Tests for Ctrl + scroll zoom (calendar/zoom.js).
 */
import { expect, test } from "vitest";
import { MAX_HOUR, MIN_HOUR, zoomedHour } from "../../calendar/zoom.js";

test("scrolling up zooms in and down zooms out", () => {
  expect(zoomedHour(52, -100)).toBe(64);
  expect(zoomedHour(52, 100)).toBe(43);
});

test("stays between the smallest and the largest hour", () => {
  expect(zoomedHour(120, -1000)).toBe(MAX_HOUR);
  expect(zoomedHour(30, 1000)).toBe(MIN_HOUR);
});
