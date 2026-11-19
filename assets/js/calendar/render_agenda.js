/**
 * HTML for the agenda: a heading per day with something on it (today marked
 * for assistive technology as well as by colour), and each event as a row
 * that opens its preview. The list ends in a sentinel the hook watches to
 * load the next weeks, or, once the agenda has gone as far as it goes, in
 * "Show later". The list is its own scroller (`data-view-scroll`), headed
 * by the lens: All or only Bookings (`data-agenda-lens`, the one shown
 * pressed). Pure; every string comes from the server and is escaped.
 */
import { colour, dateLabel, escapeHtml, interpolate, ownColour, requestAria, requestFlag } from "./render.js";
import { AGENDA_LENSES } from "./agenda.js";
import { dayNumber, formatMinutes, isoWeekday } from "./time.js";

export function renderAgenda({ groups, strings, timeFormat, now, done, loading = false, lens = "all" }) {
  const opts = { strings, timeFormat, now };
  const empty = lens === "bookings" ? strings.agenda_no_bookings : strings.agenda_empty;
  const list = groups.length
    ? `<ol class="cal-agenda-days">${groups.map((group) => renderAgendaDay(group, opts)).join("")}</ol>`
    : `<p class="cal-agenda-empty" role="note">${escapeHtml(empty)}</p>`;
  const end = done
    ? `<button type="button" class="cal-agenda-later" data-agenda-later>${escapeHtml(strings.agenda_later)}</button>`
    : `<p class="cal-agenda-more" data-agenda-sentinel>${escapeHtml(strings.agenda_loading)}</p>`;
  return `<div class="cal-agenda" data-view-scroll role="region" aria-label="${escapeHtml(strings.agenda_label)}"${loading ? ' aria-busy="true"' : ""}>${lensBar(lens, strings)}${list}${end}</div>`;
}

function lensBar(lens, strings) {
  const labels = { all: strings.agenda_lens_all, bookings: strings.agenda_lens_bookings };
  const buttons = AGENDA_LENSES.map(
    (value) => `<button type="button" data-agenda-lens="${value}" aria-pressed="${value === lens}">${escapeHtml(labels[value])}</button>`,
  ).join("");
  return `<div class="cal-agenda-lens" role="group" aria-label="${escapeHtml(strings.agenda_lens_label)}">${buttons}</div>`;
}

// One day as a list item (`<li>`), or the empty-day note when `group` is null.
export function renderAgendaDay(group, opts) {
  const { strings } = opts;
  if (!group) return `<p class="cal-agenda-empty" role="note">${escapeHtml(strings.empty_day)}</p>`;
  const { day, today, items } = group;
  const [, month, date] = day.split("-").map(Number);
  const heading =
    `<h2 class="cal-agenda-date"${today ? ' aria-current="date"' : ""}>` +
    `<span class="cal-agenda-weekday">${escapeHtml(strings.weekdays[isoWeekday(dayNumber(day)) - 1])}</span> ` +
    `<span class="cal-agenda-num">${date}</span> ` +
    `<span class="cal-agenda-month">${escapeHtml(strings.months[month - 1])}</span>` +
    (today ? ` <span class="cal-agenda-today">${escapeHtml(strings.today)}</span>` : "") +
    `</h2>`;
  const rows = items.map((item) => `<li>${row(item, day, opts)}</li>`).join("");
  return `<li class="cal-agenda-day${today ? " is-today" : ""}" data-agenda-day="${day}" data-day="${day}">${heading}<ul class="cal-agenda-items">${rows}</ul></li>`;
}

function row(item, day, { strings, timeFormat, now }) {
  const e = item.event;
  const time = timeText(item, strings, timeFormat);
  const flag = requestFlag(e, strings);
  const past = e.endMin <= now;
  const free = e.free && !e.expired;
  const classes = ["cal-agenda-row", past && "is-past", free && "is-free", e.kind === "booking" && "is-booking", ownColour(e) && "has-colour", flag && "is-request", e.expired && "is-expired", e.attention && "is-attention"].filter(Boolean).join(" ");
  const label = [e.title, flag && requestAria(e, strings), dateLabel(day, strings), time, free && strings.shown_as_free, past && strings.ended, e.attention && strings.waiting_to_sync].filter(Boolean).join(", ");
  return (
    `<button type="button" class="${classes}" data-event-id="${escapeHtml(e.id)}" aria-label="${escapeHtml(label)}" style="--cal-ev:${colour(e.colour)}">` +
    `<span class="cal-agenda-time">${escapeHtml(time)}</span>` +
    `<span class="cal-agenda-swatch" aria-hidden="true"></span>` +
    `<span class="cal-agenda-title">${flag ? `<span class="cal-agenda-flag">${escapeHtml(flag)}</span> ` : ""}${escapeHtml(e.title)}</span>` +
    (e.attention ? `<span class="cal-ev-dot" aria-hidden="true"></span>` : "") +
    `</button>`
  );
}

function timeText({ allDay, from, to, continuesBefore, continuesAfter }, strings, timeFormat) {
  if (allDay) return strings.all_day;
  const start = formatMinutes(from, timeFormat);
  const end = formatMinutes(to, timeFormat);
  if (continuesBefore) return interpolate(strings.agenda_until, { time: end });
  if (continuesAfter) return interpolate(strings.agenda_from, { time: start });
  return `${start}–${end}`;
}
