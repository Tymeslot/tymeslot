/**
 * Tests for the time helpers the calendar's editing needs (calendar/time.js):
 * the minute under a pixel, and a minute written back as the payload's
 * wall-clock string.
 */
import { expect, test } from "vitest";
import { MINUTES_PER_DAY, dayNumber, formatWall, makeScale, parseWall } from "../../calendar/time.js";

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

test("formatWall rounds a fractional minute instead of writing an invalid time", () => {
  const day = dayNumber("2026-10-15") * MINUTES_PER_DAY;
  expect(formatWall(day + 659.6)).toBe("2026-10-15T11:00");
  expect(formatWall(day + MINUTES_PER_DAY - 0.4)).toBe("2026-10-16T00:00");
});

test("formatWall undoes parseWall", () => {
  for (const text of ["2026-10-15T09:30", "2026-10-15T00:00", "2026-12-31T23:59"]) {
    expect(formatWall(parseWall(text))).toBe(text);
  }
});

test("minuteOf undoes yOf on a folded day, either side of the night strip", () => {
  const scale = makeScale(52, true);
  for (const minute of [0, 210, 420, 421, 540, 1000, MINUTES_PER_DAY]) {
    expect(scale.minuteOf(scale.yOf(minute))).toBeCloseTo(minute, 6);
  }
});
