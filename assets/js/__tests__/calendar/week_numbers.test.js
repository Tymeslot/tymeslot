/**
 * Tests for ISO week numbers (calendar/week_numbers.js). The cases match
 * Period.week_number/1's in test/tymeslot/calendar_grid/period_test.exs.
 */
import { describe, expect, test } from "vitest";
import { isoWeek, rowWeek } from "../../calendar/week_numbers.js";
import { addDays } from "../../calendar/time.js";

const row = (first, count = 7) => Array.from({ length: count }, (_, k) => addDays(first, k));

describe("isoWeek", () => {
  test("numbers a midweek day", () => {
    expect(isoWeek("2026-10-14")).toBe(42);
    expect(isoWeek("2026-10-12")).toBe(42);
    expect(isoWeek("2026-10-18")).toBe(42);
  });

  test("a year that starts on a Thursday has 53 weeks, and its last days run into the next year", () => {
    expect(isoWeek("2026-01-01")).toBe(1);
    expect(isoWeek("2025-12-29")).toBe(1);
    expect(isoWeek("2026-12-31")).toBe(53);
    expect(isoWeek("2027-01-01")).toBe(53);
    expect(isoWeek("2027-01-03")).toBe(53);
    expect(isoWeek("2027-01-04")).toBe(1);
  });

  test("the last days of December can be week 1 of the next year", () => {
    expect(isoWeek("2024-12-30")).toBe(1);
  });
});

describe("rowWeek", () => {
  test("a Monday-start row is numbered by its Monday", () => {
    expect(rowWeek(row("2026-10-12"))).toBe(42);
  });

  test("a Sunday-start row is numbered by the Monday after its Sunday", () => {
    expect(rowWeek(row("2026-10-11"))).toBe(42);
    expect(rowWeek(row("2026-09-27"))).toBe(40);
    expect(rowWeek(row("2027-01-03"))).toBe(1);
  });

  test("a row without a Monday is numbered by its first day", () => {
    expect(rowWeek(row("2027-01-01", 3))).toBe(53);
    expect(rowWeek(["2026-10-18"])).toBe(42);
  });

  test("a week without its weekend is numbered as the whole week", () => {
    expect(rowWeek(row("2026-10-12", 5))).toBe(42);
  });
});
