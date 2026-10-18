/**
 * The all-day lane of the calendar canvas. It sits under the day headers in
 * the same CSS grid as the day columns (so the two can never misalign), draws
 * a multi-day event as one bar, and past `maxLanes` lanes folds the rest into
 * a "+N" per day.
 */
import { dayNumber, needsAnswer } from "./time.js";

export function layoutAllDay(events, days, { maxLanes }) {
  const dayNums = days.map(dayNumber);
  const first = dayNums[0];
  const last = dayNums[dayNums.length - 1];

  const long = events
    .filter((e) => e.long && e.startDay <= last && e.endDay > first)
    // A draft takes the first lane, then a request waiting for an answer, so
    // neither is folded into a "+N" while a plain event can give way.
    .sort((a, b) => (b.kind === "draft") - (a.kind === "draft") || needsAnswer(b) - needsAnswer(a) || a.startDay - b.startDay || b.endDay - b.startDay - (a.endDay - a.startDay) || (a.id < b.id ? -1 : 1));

  const laneEnds = [];
  const placed = [];

  for (const e of long) {
    const startIndex = dayNums.findIndex((d) => d >= e.startDay);
    let endIndex = -1;
    for (let i = dayNums.length - 1; i >= 0; i -= 1) {
      if (dayNums[i] < e.endDay) {
        endIndex = i;
        break;
      }
    }
    // Falls entirely on days the view leaves out (hidden weekends).
    if (startIndex < 0 || endIndex < startIndex) continue;

    let lane = laneEnds.findIndex((end) => end < startIndex);
    if (lane < 0) {
      lane = laneEnds.length;
      laneEnds.push(endIndex);
    } else {
      laneEnds[lane] = endIndex;
    }

    placed.push({
      id: e.id,
      startIndex,
      endIndex,
      lane,
      cutStart: e.startDay < dayNums[startIndex],
      cutEnd: e.endDay - 1 > dayNums[endIndex],
    });
  }

  const used = laneEnds.length;
  const shown = used > maxLanes ? maxLanes - 1 : used;
  const more = days.map(() => 0);
  // Whether a "+N" hides a request waiting for an answer, which marks it.
  const warn = days.map(() => false);
  const waiting = new Set(long.filter(needsAnswer).map((e) => e.id));
  for (const bar of placed.filter((p) => p.lane >= shown)) {
    for (let i = bar.startIndex; i <= bar.endIndex; i += 1) {
      more[i] += 1;
      if (waiting.has(bar.id)) warn[i] = true;
    }
  }

  return { bars: placed.filter((p) => p.lane < shown), more, warn, rows: shown + (more.some(Boolean) ? 1 : 0) };
}
