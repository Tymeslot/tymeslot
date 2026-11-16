/**
 * The popover a day's "Bookable" label opens: what the hatched times are,
 * the labelled window, "Copy free times" and "Block this time" (which
 * carries the window it blocks). Pure HTML; the hook places and wires it
 * (hooks/calendar_canvas/bookable.js).
 */
import { dateLabel, escapeHtml, interpolate } from "./render.js";
import { MINUTES_PER_DAY, formatMinutes, parseWall } from "./time.js";

export function renderExplainer({ day, start, end, meetingType, strings, timeFormat }) {
  const time = interpolate(strings.range_on_day, {
    date: dateLabel(day, strings),
    start: formatMinutes(parseWall(start) % MINUTES_PER_DAY, timeFormat),
    finish: formatMinutes(parseWall(end) % MINUTES_PER_DAY, timeFormat),
  });

  return (
    `<div id="calendar-bookable-explainer" class="cal-bookable-pop" role="dialog" aria-modal="false" aria-labelledby="calendar-bookable-explainer-title">` +
    `<h2 id="calendar-bookable-explainer-title" class="cal-bookable-pop-title">${escapeHtml(strings.bookable_title)}</h2>` +
    `<p class="cal-bookable-pop-text">${escapeHtml(interpolate(strings.bookable_explainer, { meeting_type: meetingType }))}</p>` +
    `<p class="cal-bookable-pop-time">${escapeHtml(time)}</p>` +
    `<div class="cal-bookable-pop-actions">` +
    `<button type="button" class="cal-bookable-pop-button" data-bookable-copy>${escapeHtml(strings.copy_free_times)}</button>` +
    `<button type="button" class="cal-bookable-pop-button" data-bookable-block data-start="${escapeHtml(start)}" data-end="${escapeHtml(end)}">${escapeHtml(strings.block_this_time)}</button>` +
    `</div>` +
    `<p class="cal-bookable-pop-status" data-bookable-status role="status"></p>` +
    `<p class="cal-bookable-pop-hint">${escapeHtml(strings.bookable_hide_hint)}</p>` +
    `</div>`
  );
}
