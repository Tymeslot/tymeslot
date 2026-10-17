/**
 * Tests for the time helpers the calendar's editing needs (calendar/time.js):
 * the minute under a pixel, and a minute written back as the payload's
 * wall-clock string.
 */
import { expect, test } from "vitest";
import { MINUTES_PER_DAY, dayNumber, formatWall, makeScale } from "../../calendar/time.js";

test("minuteOf undoes yOf on an unfolded day", () => {
  const scale = makeScale(52, false);
  expect(scale.minuteOf(scale.yOf(660))).toBe(660);
  expect(scale.minuteOf(26)).toBe(30);
});

test("minuteOf reads the folded night strip and the hours below it", () => {
  const scale = makeScale(52, true);
  expect(scale.minuteOf(14)).toBe(210);
  expect(scale.minuteOf(28 + 52)).toBe(480);
});

test("minuteOf stays within the day", () => {
  const scale = makeScale(52, false);
  expect(scale.minuteOf(-10)).toBe(0);
  expect(scale.minuteOf(100_000)).toBe(MINUTES_PER_DAY);
});

test("formatWall writes a minute as the payload's wall-clock string", () => {
  const day = dayNumber("2026-10-15") * MINUTES_PER_DAY;
  expect(formatWall(day + 660)).toBe("2026-10-15T11:00");
  expect(formatWall(day + MINUTES_PER_DAY)).toBe("2026-10-16T00:00");
});
