/**
 * HTML for the phone's week strip above Day view: the week's seven days,
 * each a 44px button that opens its day (`data-goto-day`, which the hook
 * already handles for day headers), with up to three dots for its events.
 * Pure; every string is escaped.
 */
import { dayDots } from "./month.js";
import { dotsHtml } from "./render_month.js";
import { dateLabel, escapeHtml, interpolate } from "./render.js";
import { dayNumber, isoWeekday } from "./time.js";

export function renderWeekStrip({ days, date, today, events, strings }) {
  const cells = days
    .map((iso) => {
      const label = interpolate(strings.open_day, { date: dateLabel(iso, strings) });
      return (
        `<button type="button" class="cal-strip-day${iso === today ? " is-today" : ""}" data-goto-day="${iso}" aria-pressed="${iso === date}" aria-label="${escapeHtml(label)}"${iso === today ? ' aria-current="date"' : ""}>` +
        `<span class="cal-strip-name">${escapeHtml(strings.weekdays[isoWeekday(dayNumber(iso)) - 1])}</span>` +
        `<span class="cal-strip-num">${Number(iso.slice(8, 10))}</span>${dotsHtml(dayDots(events, iso))}</button>`
      );
    })
    .join("");
  return `<nav class="cal-strip" aria-label="${escapeHtml(strings.strip_label)}">${cells}</nav>`;
}
