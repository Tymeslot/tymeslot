/**
 * HTML for the month view: six weeks of seven days (calendar/month.js lays
 * them out). Wide, each week is a CSS grid: a cell per day holding its
 * day-number button (the roving tab stop, `data-month-day`), bars for
 * all-day and multi-day events, chips for timed ones, and a "+N"
 * (`data-month-more`) for what does not fit. On a phone (`phone`) each day
 * is one button with up to three dots, and the chosen day (`date`) lists
 * its events below the grid (render_agenda.js). The month is its own
 * scroller (`data-view-scroll`). Pure; every string is escaped.
 */
import { agendaGroups } from "./agenda.js";
import { chipCapacity, dayDots, eventsOnDay, monthLayout, monthWeeks } from "./month.js";
import { renderAgendaDay } from "./render_agenda.js";
import { badgeNotes, colour, ownColour, repliesTone, dateLabel, escapeHtml, interpolate, requestAria, requestFlag, weekNumberHtml } from "./render.js";
import { MINUTES_PER_DAY, dayNumber, formatMinutes, isoFromDay, isoWeekday } from "./time.js";

const HEAD_ROW = 24;
const LANE = 20;

export function renderMonth({ days, date, today, events, settings, strings, phone = false, cellHeight = 96, now }) {
  const weeks = monthWeeks(days);
  const month = date.slice(0, 7);
  const focus = days.includes(date) ? date : (days.find((iso) => iso.startsWith(month)) ?? days[0]);
  const ctx = { month, date, today, focus, events, settings, strings, now };
  const [year, monthNumber] = month.split("-").map(Number);
  const label = `${strings.months[monthNumber - 1]} ${year}`;
  const head = weeks[0].map((iso) => `<span class="cal-month-weekday">${escapeHtml(strings.weekdays[isoWeekday(dayNumber(iso)) - 1])}</span>`).join("");
  const body = phone ? weeks.map((week) => phoneWeek(week, ctx)).join("") : wideWeeks(weeks, cellHeight, ctx);

  return (
    `<div class="cal-month${phone ? " is-phone" : ""}${settings.show_week_numbers ? " has-weeknums" : ""}" data-view-scroll role="region" aria-label="${escapeHtml(label)}">` +
    `<div class="cal-month-head" aria-hidden="true">${head}</div>` +
    `<div class="cal-month-weeks">${body}</div>` +
    (phone ? chosenDay(ctx) : "") +
    `</div>`
  );
}

// Dots for a day (`dayDots`), shared with the week strip. `extra` is one more
// class on each dot (`cal-month-dot` in the month, which tests and the
// browser check look for).
export function dotsHtml(dots, extra = "") {
  const cls = `cal-dot${extra ? ` ${extra}` : ""}`;
  return `<span class="cal-dots" aria-hidden="true">${dots.map((d) => `<span class="${cls}${d.attention ? " is-attention" : ""}${d.free ? " is-free" : ""}" style="--cal-ev:${colour(d.colour)}"></span>`).join("")}</span>`;
}

function wideWeeks(weeks, cellHeight, ctx) {
  const lanes = chipCapacity(cellHeight, { head: HEAD_ROW, row: LANE });
  const byId = new Map(ctx.events.map((e) => [e.id, e]));
  return monthLayout(weeks, ctx.events, { maxLanes: lanes })
    .map((week) => {
      let html = `<div class="cal-mweek" style="grid-template-rows:${HEAD_ROW}px repeat(${lanes}, ${LANE}px) minmax(0, 1fr)">${weekNumberHtml(week.days, ctx.settings, ctx.strings)}`;
      // Each day's cell is followed by its bars (from the day they start on),
      // chips and "+N", so the document reads day by day; the grid placement
      // is explicit, so the picture does not depend on this order.
      week.days.forEach((iso, i) => {
        html += cell(iso, i, ctx);
        for (const bar of week.bars) if (bar.startIndex === i) html += monthBar(bar, byId.get(bar.id), iso, ctx);
        const first = 2 + week.barRows;
        week.chips[iso].forEach((e, k) => (html += monthChip(e, iso, i, first + k, ctx)));
        if (week.more[iso]) html += moreButton(iso, i, first + week.chips[iso].length, week.more[iso], week.warn[iso], ctx);
      });
      return `${html}</div>`;
    })
    .join("");
}

function cellClasses(iso, { month, today }, extra = []) {
  return ["cal-mday", ...extra, !iso.startsWith(month) && "is-other-month", isoWeekday(dayNumber(iso)) > 5 && "is-weekend", iso === today && "is-today"].filter(Boolean).join(" ");
}

function cell(iso, column, ctx) {
  const { today, focus, strings } = ctx;
  const label = interpolate(strings.open_day, { date: dateLabel(iso, strings) });
  return (
    `<div class="${cellClasses(iso, ctx)}" data-month-cell="${iso}" style="grid-column:${column + 1};grid-row:1 / -1">` +
    `<button type="button" class="cal-mday-num" data-month-day="${iso}" tabindex="${iso === focus ? 0 : -1}" aria-label="${escapeHtml(label)}"${iso === today ? ' aria-current="date"' : ""}>${Number(iso.slice(8, 10))}</button>` +
    `</div>`
  );
}

function eventClasses(base, e, past, flag, extra = []) {
  return [base, ...extra, past && "is-past", e.free && !e.expired && "is-free", e.kind === "booking" && "is-booking", ownColour(e) && "has-colour", flag && "is-request", e.expired && "is-expired", e.attention && "is-attention"].filter(Boolean).join(" ");
}

function monthBar(bar, e, iso, { settings, strings, now }) {
  const flag = requestFlag(e, strings);
  const past = e.endMin <= now;
  const first = dateLabel(isoFromDay(e.startDay), strings);
  const span = e.endDay - e.startDay > 1 ? `${first} – ${dateLabel(isoFromDay(e.endDay - 1), strings)}` : first;
  const when = e.all_day ? strings.all_day : `${formatMinutes(e.startMin % MINUTES_PER_DAY, settings.time_format)}–${formatMinutes(e.endMin % MINUTES_PER_DAY, settings.time_format)}`;
  const label = [e.title, flag && requestAria(e, strings), when, span, past && strings.ended, ...badgeNotes(e, strings)].filter(Boolean).join(", ");
  const classes = eventClasses("cal-mbar", e, past, flag, [bar.cutStart && "cut-start", bar.cutEnd && "cut-end"]);
  return (
    `<button type="button" class="${classes}" data-event-id="${escapeHtml(e.id)}" data-day="${iso}" aria-label="${escapeHtml(label)}" ` +
    `style="grid-column:${bar.startIndex + 1} / ${bar.endIndex + 2};grid-row:${bar.lane + 2};--cal-ev:${colour(e.colour)}">` +
    `${flag ? `<span class="cal-mchip-flag">${escapeHtml(flag)}</span> ` : ""}${escapeHtml(e.title)}${repliesDot(e)}</button>`
  );
}

// The guests' answers as a dot in their tone; the item's accessible name
// says them (badgeNotes).
function repliesDot(e) {
  return e.replies ? `<span class="cal-mreplies ${repliesTone(e.replies)}" aria-hidden="true"></span>` : "";
}

function monthChip(e, iso, column, row, { settings, strings, now }) {
  const tf = settings.time_format;
  const flag = requestFlag(e, strings);
  const past = e.endMin <= now;
  const range = `${formatMinutes(e.startMin % MINUTES_PER_DAY, tf)}–${formatMinutes(e.endMin % MINUTES_PER_DAY, tf)}`;
  // A chip for the day an overnight event ends on starts at midnight: no time.
  const start = e.startMin < dayNumber(iso) * MINUTES_PER_DAY ? "" : formatMinutes(e.startMin % MINUTES_PER_DAY, tf);
  const label = [e.title, flag && requestAria(e, strings), dateLabel(iso, strings), range, e.free && !e.expired && strings.shown_as_free, past && strings.ended, e.attention && strings.waiting_to_sync, ...badgeNotes(e, strings)].filter(Boolean).join(", ");
  return (
    `<button type="button" class="${eventClasses("cal-mchip", e, past, flag)}" data-event-id="${escapeHtml(e.id)}" data-day="${iso}" aria-label="${escapeHtml(label)}" ` +
    `style="grid-column:${column + 1};grid-row:${row};--cal-ev:${colour(e.colour)}">` +
    `<span class="cal-mchip-dot" aria-hidden="true"></span>` +
    (start ? `<span class="cal-mchip-time">${escapeHtml(start)}</span>` : "") +
    `<span class="cal-mchip-title">${flag ? `<span class="cal-mchip-flag">${escapeHtml(flag)}</span> ` : ""}${escapeHtml(e.title)}</span>` +
    repliesDot(e) +
    (e.attention ? `<span class="cal-ev-dot" aria-hidden="true"></span>` : "") +
    `</button>`
  );
}

function moreButton(iso, column, row, count, warn, { strings }) {
  const label = [interpolate(strings.month_more, { count, date: dateLabel(iso, strings) }), warn && strings.month_attention].filter(Boolean).join(", ");
  return (
    `<button type="button" class="cal-mmore${warn ? " is-warn" : ""}" data-month-more="${iso}" aria-haspopup="dialog" aria-label="${escapeHtml(label)}" ` +
    `style="grid-column:${column + 1};grid-row:${row}">+${count}</button>`
  );
}

function phoneWeek(week, ctx) {
  return `<div class="cal-mweek is-phone">${weekNumberHtml(week, ctx.settings, ctx.strings)}${week.map((iso) => phoneCell(iso, ctx)).join("")}</div>`;
}

function phoneCell(iso, ctx) {
  const { date, today, focus, events, strings } = ctx;
  const count = eventsOnDay(events, iso).length;
  const label = [interpolate(strings.month_select, { date: dateLabel(iso, strings) }), count && interpolate(strings.day_events, { count })].filter(Boolean).join(", ");
  return (
    `<button type="button" class="${cellClasses(iso, ctx, ["is-phone"])}" data-month-day="${iso}" tabindex="${iso === focus ? 0 : -1}" ` +
    `aria-pressed="${iso === date}" aria-label="${escapeHtml(label)}"${iso === today ? ' aria-current="date"' : ""}>` +
    `<span class="cal-mday-num">${Number(iso.slice(8, 10))}</span>${dotsHtml(dayDots(events, iso), "cal-month-dot")}</button>`
  );
}

function chosenDay({ date, today, events, settings, strings, now }) {
  const [group] = agendaGroups(events, [date], { today });
  const day = renderAgendaDay(group ?? null, { strings, timeFormat: settings.time_format, now });
  return `<section class="cal-month-agenda" aria-label="${escapeHtml(dateLabel(date, strings))}">${group ? `<ol class="cal-agenda-days">${day}</ol>` : day}</section>`;
}
