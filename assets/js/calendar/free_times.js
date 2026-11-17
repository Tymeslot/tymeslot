/**
 * "Copy free times": the bookable windows on the visible days as plain
 * text to paste into an email, one line per day with bookable times, in
 * the organiser's clock, then the time zone they are in. Pure.
 */
import { windowsForDay } from "./bookable.js";
import { dateLabel, interpolate } from "./render.js";
import { formatMinutes } from "./time.js";

export function formatFreeTimes(windows, days, { timezone, timeFormat, strings }) {
  const lines = days.flatMap((day) => {
    const parts = windowsForDay(windows, day);
    if (parts.length === 0) return [];
    const times = parts
      .map(({ startMin, endMin }) => interpolate(strings.time_range, { start: formatMinutes(startMin, timeFormat), finish: formatMinutes(endMin, timeFormat) }))
      .join(", ");
    return [interpolate(strings.free_times_day, { date: dateLabel(day, strings), times })];
  });
  const body = lines.length ? lines : [strings.free_times_none];
  return [...body, interpolate(strings.free_times_zone, { zone: timezone })].join("\n");
}
