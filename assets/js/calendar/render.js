/**
 * HTML for the calendar canvas: the time grid, its first-paint skeleton, and
 * the list a "+N more" chip opens. Pure functions of their arguments; the
 * hook sets the result as its element's contents.
 *
 * Every server string is escaped, and colour tokens must match TOKEN before
 * they reach a style attribute. All copy comes from the strings map the
 * server renders into `data-strings`; nothing here is hard-coded English.
 */
import { layoutAllDay } from "./allday.js";
import { countLines, layoutColumn } from "./layout.js";
import {
  HOUR_HEIGHT,
  MINUTES_PER_DAY,
  NIGHT_END,
  NIGHT_STRIP,
  dayNumber,
  formatHour,
  formatMinutes,
  isoFromDay,
  isoWeekday,
  makeScale,
  segmentsForDay,
} from "./time.js";

export const AXIS_WIDTH = 56;
const ALL_DAY_ROW = 22;
const ALL_DAY_LANES = 3;
const TOKEN = /^[a-z0-9-]+$/;
const ENTITIES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ENTITIES[c]);
}

export function interpolate(template, vars) {
  return String(template ?? "").replace(/%\{(\w+)\}/g, (_match, key) => (key in vars ? String(vars[key]) : ""));
}

function colour(token) {
  if (token === "booking") return "var(--cal-booking)";
  return TOKEN.test(token || "") ? `var(--color-${token})` : "var(--color-calendar-fallback)";
}

export function dateLabel(iso, strings) {
  const [, month, day] = iso.split("-").map(Number);
  return `${strings.weekdays[isoWeekday(dayNumber(iso)) - 1]} ${day} ${strings.months[month - 1]}`;
}

function emptyText(view, strings) {
  if (view === "day") return strings.empty_day;
  if (view === "three_day") return strings.empty_three_day;
  return strings.empty_week;
}

export function renderGrid(model) {
  const { view, days, events, settings, strings, now, width, measureWidth, nightOpen } = model;
  const hourHeight = HOUR_HEIGHT[settings.density] || HOUR_HEIGHT.comfortable;
  const fold = settings.fold_night && !nightOpen;
  const scale = makeScale(hourHeight, fold);
  const colWidth = Math.max(40, (width - AXIS_WIDTH - 1) / days.length);
  const nowDay = isoFromDay(Math.floor(now / MINUTES_PER_DAY));
  const nowMinute = now % MINUTES_PER_DAY;
  const nowShown = days.includes(nowDay) && (!fold || nowMinute > NIGHT_END);
  const byId = new Map(events.map((e) => [e.id, e]));
  const allDay = layoutAllDay(events, days, { maxLanes: ALL_DAY_LANES });
  const timedCount = days.reduce((sum, iso) => sum + segmentsForDay(events, iso).length, 0);
  const empty = timedCount === 0 && allDay.bars.length === 0 && allDay.more.every((count) => count === 0);
  const ctx = { settings, strings, now, scale, fold, colWidth, measureWidth, byId, nowDay, nowMinute, nowShown };

  return (
    `<div class="cal-grid" data-density="${escapeHtml(settings.density)}" style="--cal-days:${days.length};--cal-axis:${AXIS_WIDTH}px;--cal-hour:${hourHeight}px;--cal-strip:${fold ? NIGHT_STRIP : 0}px">` +
    `<div class="cal-scroll" data-scroll>` +
    `<div class="cal-top">${head(days, ctx)}${allDayLane(allDay, days, ctx)}</div>` +
    `<div class="cal-body" style="height:${Math.ceil(scale.height)}px">` +
    `<div class="cal-axis">${axis(ctx)}</div>` +
    `<div class="cal-cols">${days.map((iso) => column(iso, events, ctx)).join("")}</div>` +
    `</div></div>` +
    (empty ? `<p class="cal-empty" role="note">${escapeHtml(emptyText(view, strings))}</p>` : "") +
    `</div>`
  );
}

function head(days, { strings, nowDay }) {
  const cells = days
    .map((iso) => {
      const n = dayNumber(iso);
      const label = interpolate(strings.open_day, { date: dateLabel(iso, strings) });
      return (
        `<button type="button" class="cal-dayhead${iso === nowDay ? " is-today" : ""}" data-goto-day="${iso}" aria-label="${escapeHtml(label)}">` +
        `<span class="cal-dayhead-name">${escapeHtml(strings.weekdays[isoWeekday(n) - 1])}</span>` +
        `<span class="cal-dayhead-num">${Number(iso.slice(8, 10))}</span></button>`
      );
    })
    .join("");
  return `<div class="cal-head"><div class="cal-head-corner"></div>${cells}</div>`;
}

function allDayLane({ bars, more, rows }, days, { strings, now, byId }) {
  const template = rows ? `repeat(${rows}, ${ALL_DAY_ROW}px)` : "8px";
  let html = `<div class="cal-allday" style="grid-template-rows:${template}"><div class="cal-allday-label" style="grid-row:1 / -1">${rows ? escapeHtml(strings.all_day) : ""}</div>`;

  for (const bar of bars) {
    const e = byId.get(bar.id);
    const first = dateLabel(isoFromDay(e.startDay), strings);
    const span = e.endDay - e.startDay > 1 ? `${first} – ${dateLabel(isoFromDay(e.endDay - 1), strings)}` : first;
    const label = [e.title, strings.all_day, span, e.endMin <= now && strings.ended].filter(Boolean).join(", ");
    const classes = ["cal-adbar", bar.cutStart && "cut-start", bar.cutEnd && "cut-end", e.endMin <= now && "is-past", e.free && "is-free", e.kind === "booking" && "is-booking"]
      .filter(Boolean)
      .join(" ");
    html +=
      `<button type="button" class="${classes}" data-event-id="${escapeHtml(e.id)}" aria-label="${escapeHtml(label)}" ` +
      `style="grid-column:${bar.startIndex + 2} / ${bar.endIndex + 3};grid-row:${bar.lane + 1};--cal-ev:${colour(e.colour)}">${escapeHtml(e.title)}</button>`;
  }

  more.forEach((count, i) => {
    if (count) html += `<button type="button" class="cal-admore" data-allday-more="${days[i]}" style="grid-column:${i + 2};grid-row:${rows}">+${count}</button>`;
  });

  return `${html}</div>`;
}

function axis({ scale, fold, settings, strings, nowShown, nowMinute }) {
  const tf = settings.time_format;
  const time = formatMinutes(NIGHT_END, tf);
  let html = "";

  if (fold) {
    const label = interpolate(strings.show_early_hours, { time });
    html += `<button type="button" class="cal-night" data-night-toggle aria-expanded="false" aria-label="${escapeHtml(label)}">${escapeHtml(shortHour(0, tf))}–${escapeHtml(shortHour(7, tf))}</button>`;
  } else if (settings.fold_night) {
    const label = interpolate(strings.fold_early_hours, { time });
    html += `<button type="button" class="cal-night is-open" data-night-toggle aria-expanded="true" aria-label="${escapeHtml(label)}"></button>`;
  }

  for (let hour = fold ? 8 : 1; hour < 24; hour += 1) {
    if (nowShown && Math.abs(hour * 60 - nowMinute) <= 15) continue;
    html += `<span class="cal-hour" style="top:${scale.yOf(hour * 60)}px">${escapeHtml(formatHour(hour, tf))}</span>`;
  }

  if (nowShown) html += `<span class="cal-now-pill" style="top:${scale.yOf(nowMinute)}px">${escapeHtml(formatMinutes(nowMinute, tf))}</span>`;

  return html;
}

function shortHour(hour, timeFormat) {
  if (timeFormat === "12h") return String(hour % 12 === 0 ? 12 : hour % 12);
  return String(hour).padStart(2, "0");
}

function column(iso, events, ctx) {
  const { scale, fold, colWidth, measureWidth, settings, strings, byId, nowDay, nowMinute, nowShown } = ctx;
  const weekday = isoWeekday(dayNumber(iso));
  let html = `<div class="cal-col${weekday > 5 ? " is-weekend" : ""}" data-day="${iso}" style="--cal-col:${colWidth}px">`;

  for (const [from, to] of offHours(settings.working_hours ? settings.working_hours[weekday] : null, scale.firstMinute)) {
    html += `<div class="cal-off" style="top:${scale.yOf(from)}px;height:${scale.yOf(to) - scale.yOf(from)}px"></div>`;
  }

  let segments = segmentsForDay(events, iso);
  if (fold) {
    const early = segments.filter((g) => g.e <= NIGHT_END).length;
    const time = formatMinutes(NIGHT_END, settings.time_format);
    const label = interpolate(strings.show_early_hours, { time });
    html += `<button type="button" class="cal-early" data-night-toggle aria-label="${escapeHtml(label)}">${early ? escapeHtml(interpolate(strings.early_hours, { time, count: early })) : ""}</button>`;
    segments = segments.filter((g) => g.e > NIGHT_END).map((g) => ({ ...g, s: Math.max(g.s, NIGHT_END) }));
  }

  const laid = layoutColumn(segments, {
    colWidth: colWidth - 6,
    hourHeight: scale.hourHeight,
    yOf: scale.yOf,
    measureLines: (text, w) => countLines(text, w, measureWidth),
  });

  for (const item of laid) html += item.chip ? chip(item, byId, strings) : eventBlock(item, byId.get(item.id), ctx);
  if (nowShown && iso === nowDay) html += `<div class="cal-now" style="top:${scale.yOf(nowMinute)}px" aria-hidden="true"></div>`;

  return `${html}</div>`;
}

function offHours(hours, first) {
  if (!hours) return [[first, MINUTES_PER_DAY]];
  const [start, end] = hours;
  const out = [];
  if (start > first) out.push([first, start]);
  if (end < MINUTES_PER_DAY) out.push([Math.max(end, first), MINUTES_PER_DAY]);
  return out;
}

function eventBlock(item, event, { strings, settings, now }) {
  const tf = settings.time_format;
  const short = item.height < 38;
  const past = event.endMin <= now;
  const start = formatMinutes(event.startMin % MINUTES_PER_DAY, tf);
  const range = `${start}–${formatMinutes(event.endMin % MINUTES_PER_DAY, tf)}`;
  const time = item.hideTime ? "" : short || item.width < 110 ? start : range;
  const classes = ["cal-ev", short && "is-short", item.width < 92 && "is-narrow", past && "is-past", event.free && "is-free", event.kind === "booking" && "is-booking", event.attention && "is-attention"]
    .filter(Boolean)
    .join(" ");
  const label = [event.title, dateLabel(isoFromDay(event.startDay), strings), range, event.free && strings.shown_as_free, past && strings.ended, event.attention && strings.waiting_to_sync]
    .filter(Boolean)
    .join(", ");
  const style =
    `top:${item.top}px;height:${item.height}px;--l:${item.left + 1}px;--w:${Math.max(item.width - 3, 12)}px;--z:${item.z};--cal-ev:${colour(event.colour)}` +
    (item.lineClamp ? `;--cal-lines:${item.lineClamp}` : "");
  const timeHtml = time ? `<span class="cal-ev-time"${item.timeGap ? ` style="margin-top:${Math.round(item.timeGap)}px"` : ""}>${escapeHtml(time)}</span>` : "";

  return (
    `<div class="${classes}" role="button" tabindex="0" data-event-id="${escapeHtml(event.id)}" aria-label="${escapeHtml(label)}" style="${style}">` +
    `<span class="cal-ev-title">${escapeHtml(event.title)}</span>${timeHtml}` +
    (event.attention ? `<span class="cal-ev-dot" aria-hidden="true"></span>` : "") +
    `</div>`
  );
}

function chip(item, byId, strings) {
  const titles = item.hidden.map((id) => byId.get(id)?.title).filter(Boolean).join(", ");
  const label = interpolate(strings.also_here, { titles }) + (item.warn ? `, ${strings.waiting_to_sync}` : "");
  return (
    `<button type="button" class="cal-more${item.warn ? " is-warn" : ""}" data-more="${escapeHtml(item.ids.join(","))}" data-hidden="${escapeHtml(item.hidden.join(","))}" ` +
    `aria-label="${escapeHtml(label)}" style="top:${item.top}px;height:${item.height}px;--l:${item.left + 1}px;--w:${item.width - 2}px;--z:${item.z}">` +
    `+${item.hidden.length}<small>${escapeHtml(strings.more)}</small>` +
    (item.warn ? `<span class="cal-more-dot" aria-hidden="true"></span>` : "") +
    `</button>`
  );
}

export function renderSkeleton(days, strings) {
  const columns = days
    .map(() => `<div class="cal-skeleton-col"><span class="cal-skeleton-block animate-shimmer"></span><span class="cal-skeleton-block is-short animate-shimmer"></span></div>`)
    .join("");
  return `<div class="cal-grid is-loading" role="status" aria-label="${escapeHtml(strings.loading)}" style="--cal-days:${days.length};--cal-axis:${AXIS_WIDTH}px"><div class="cal-skeleton">${columns}</div></div>`;
}

export function renderList(events, { strings, timeFormat, label }) {
  const items = events
    .map(
      (e) =>
        `<button type="button" class="cal-list-item" data-event-id="${escapeHtml(e.id)}" style="--cal-ev:${colour(e.colour)}">` +
        `<span class="cal-list-swatch" aria-hidden="true"></span>` +
        `<span class="cal-list-title">${escapeHtml(e.title)}</span>` +
        `<span class="cal-list-time">${escapeHtml(e.all_day ? strings.all_day : formatMinutes(e.startMin % MINUTES_PER_DAY, timeFormat))}</span>` +
        (e.attention ? `<span class="cal-ev-dot" aria-hidden="true"></span>` : "") +
        `</button>`,
    )
    .join("");
  return `<div class="cal-list" role="dialog" aria-label="${escapeHtml(label)}">${items}</div>`;
}
