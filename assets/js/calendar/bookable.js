/**
 * The bookable-times layer's geometry. The server sends the windows when
 * guests can book the chosen meeting type (`calendar:bookable`, see
 * TymeslotWeb.Dashboard.Calendar.BookableLayer) as wall-clock times in the
 * organiser's zone; a window may cross midnight. Here they are cut into one
 * band per day column, clipped to the hours the grid draws. Pure functions;
 * render.js draws the result.
 */
import { MINUTES_PER_DAY, dayNumber, parseWall } from "./time.js";

// The windows as wall-clock minute ranges, without empty or backwards ones.
function spans(windows) {
  return (windows || []).map((w) => ({ start: parseWall(w.start), end: parseWall(w.end) })).filter((s) => s.end > s.start);
}

/** The parts of `windows` on `day` ("2026-10-15"), as minutes from its midnight, in time order. */
export function windowsForDay(windows, day) {
  const dayStart = dayNumber(day) * MINUTES_PER_DAY;
  const dayEnd = dayStart + MINUTES_PER_DAY;
  return spans(windows)
    .filter((s) => s.start < dayEnd && s.end > dayStart)
    .map((s) => ({ startMin: Math.max(s.start, dayStart) - dayStart, endMin: Math.min(s.end, dayEnd) - dayStart }))
    .sort((a, b) => a.startMin - b.startMin);
}

/** One band per window part on each of `days`, clipped to [firstMinute, lastMinute]. */
export function bandsForColumns(windows, days, firstMinute, lastMinute) {
  return days.flatMap((day) =>
    windowsForDay(windows, day)
      .map(({ startMin, endMin }) => ({ day, startMin: Math.max(startMin, firstMinute), endMin: Math.min(endMin, lastMinute) }))
      .filter((band) => band.endMin > band.startMin),
  );
}

/** Where each day's one label goes: the start of its earliest band. */
export function labelPlacement(bands) {
  const first = new Map();
  for (const band of bands) {
    if (!first.has(band.day) || band.startMin < first.get(band.day)) first.set(band.day, band.startMin);
  }
  return [...first].map(([day, startMin]) => ({ day, startMin }));
}

/** Whether the next bookable time (`{at, label}`) falls on one of `days`. */
export function nextInView(next, days) {
  return !!next && days.includes(next.at.slice(0, 10));
}

/** Whether a window on one of `days` ends after `now` (a wall-clock minute). */
export function bookableInView(windows, days, now) {
  return days.some((day) => {
    const dayStart = dayNumber(day) * MINUTES_PER_DAY;
    return windowsForDay(windows, day).some(({ endMin }) => dayStart + endMin > now);
  });
}
