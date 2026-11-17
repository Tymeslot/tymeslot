/**
 * What the calendar canvas's live region says during the keyboard move
 * mode. Pure functions of the strings map the server renders into
 * `data-strings` (see ClientStrings), so no English lives here.
 */
import { dateLabel, interpolate } from "./render.js";
import { MINUTES_PER_DAY, formatMinutes, isoFromDay } from "./time.js";

export function rangeText(range, strings, timeFormat) {
  const day = Math.floor(range.startMin / MINUTES_PER_DAY);
  return interpolate(strings.range_on_day, {
    date: dateLabel(isoFromDay(day), strings),
    start: formatMinutes(range.startMin - day * MINUTES_PER_DAY, timeFormat),
    finish: formatMinutes(range.endMin % MINUTES_PER_DAY, timeFormat),
  });
}

export function movingText(title, range, strings, timeFormat) {
  return interpolate(strings.moving, { title: title ?? "", when: rangeText(range, strings, timeFormat) });
}

export function cancelledText(title, range, strings, timeFormat) {
  return interpolate(strings.move_cancelled, { title: title ?? "", when: rangeText(range, strings, timeFormat) });
}

export function savingText(title, range, strings, timeFormat) {
  return interpolate(strings.move_saving, { title: title ?? "", when: rangeText(range, strings, timeFormat) });
}
