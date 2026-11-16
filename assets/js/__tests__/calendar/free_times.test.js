/**
 * Tests for "Copy free times" (calendar/free_times.js): one line per day
 * with bookable times, in the organiser's clock, then the time zone.
 */
import { expect, test } from "vitest";
import { formatFreeTimes } from "../../calendar/free_times.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  free_times_day: "%{date}: %{times}",
  free_times_zone: "Times in %{zone}",
  free_times_none: "No bookable times on these days.",
  time_range: "%{start} to %{finish}",
};
const week = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"];
const w = (start, end) => ({ start, end });
const options = { timezone: "Europe/London", timeFormat: "24h", strings };

test("one line per day with bookable times, then the time zone", () => {
  const windows = [w("2026-10-15T09:00", "2026-10-15T17:00"), w("2026-10-12T14:00", "2026-10-12T17:30"), w("2026-10-12T09:00", "2026-10-12T12:00")];

  expect(formatFreeTimes(windows, week, options)).toBe("Mon 12 Oct: 09:00 to 12:00, 14:00 to 17:30\nThu 15 Oct: 09:00 to 17:00\nTimes in Europe/London");
});

test("only the days given, with a window across midnight on both", () => {
  const windows = [w("2026-10-15T22:00", "2026-10-16T02:00"), w("2026-10-26T09:00", "2026-10-26T10:00")];

  expect(formatFreeTimes(windows, week, options)).toBe("Thu 15 Oct: 22:00 to 00:00\nFri 16 Oct: 00:00 to 02:00\nTimes in Europe/London");
});

test("in the organiser's 12-hour clock", () => {
  expect(formatFreeTimes([w("2026-10-15T09:00", "2026-10-15T13:30")], week, { ...options, timeFormat: "12h" })).toBe("Thu 15 Oct: 9:00 AM to 1:30 PM\nTimes in Europe/London");
});

test("says so when nothing is bookable", () => {
  expect(formatFreeTimes([], week, options)).toBe("No bookable times on these days.\nTimes in Europe/London");
});
