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
import { draggable } from "./drag.js";
import { LINE_HEIGHT, countLines, isLongWord, layoutColumn } from "./layout.js";
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
// An event block's border and vertical padding, and the time line under a title.
const EVENT_CHROME = 8;
const TIME_LINE = 16;
// The room a title's text has inside a block `width` wide: the block's inset,
// border and padding. countLines and the long-word marks share it.
const TITLE_INSET = 15;
// Below this a one-row block's title is a letter or two: the time beside it
// gives way. The time is 10px against the 12px the title is measured at.
const SHORT_TITLE_ROOM = 40;
const TIME_SCALE = 10 / 12;
const SHORT_GAP = 5;
// Resize hit areas: transparent strips at a draggable block's top and bottom
// edges, drawn as a grip only on hover and focus (calendar-surface.css), so
// they never paint over text. A block too short to hold both has none.
const GRIPS = `<span class="cal-ev-grip is-start" data-grip="start" aria-hidden="true"></span><span class="cal-ev-grip is-end" data-grip="end" aria-hidden="true"></span>`;
const GRIP_MIN_HEIGHT = 18;
const ENTITIES = { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" };

export function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ENTITIES[c]);
}

export function interpolate(template, vars) {
  return String(template ?? "").replace(/%\{(\w+)\}/g, (_match, key) => (key in vars ? String(vars[key]) : ""));
}

function colour(token) {
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

// The period the grid shows, for the region's accessible name.
function periodLabel(days, strings) {
  const first = dateLabel(days[0], strings);
  const last = dateLabel(days[days.length - 1], strings);
  return days.length > 1 ? interpolate(strings.period_range, { from: first, to: last }) : first;
}

export function renderGrid(model) {
  const { view, days, events, settings, strings, now, width, measureWidth, nightOpen } = model;
  // A Ctrl + scroll zoom (hooks/calendar_canvas/zoom.js) overrides the density's height.
  const hourHeight = Math.round(model.hourHeight) || HOUR_HEIGHT[settings.density] || HOUR_HEIGHT.comfortable;
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
  const movingId = model.movingId ?? null;
  const ctx = { settings, strings, now, scale, fold, colWidth, measureWidth, byId, nowDay, nowMinute, nowShown, movingId };

  return (
    `<div class="cal-grid" data-density="${escapeHtml(settings.density)}" style="--cal-days:${days.length};--cal-axis:${AXIS_WIDTH}px;--cal-hour:${hourHeight}px;--cal-strip:${fold ? NIGHT_STRIP : 0}px">` +
    `<div class="cal-scroll" data-scroll role="application" aria-roledescription="${escapeHtml(strings.calendar_role)}" aria-label="${escapeHtml(periodLabel(days, strings))}">` +
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
        `<button type="button" class="cal-dayhead${iso === nowDay ? " is-today" : ""}" data-goto-day="${iso}" aria-label="${escapeHtml(label)}"${iso === nowDay ? ' aria-current="date"' : ""}>` +
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
    if (e.kind === "draft") {
      html += draftBar(bar, e, strings);
      continue;
    }
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
    if (!count) return;
    const label = interpolate(strings.allday_more, { count, date: dateLabel(days[i], strings) });
    html += `<button type="button" class="cal-admore" data-allday-more="${days[i]}" aria-label="${escapeHtml(label)}" style="grid-column:${i + 2};grid-row:${rows}">+${count}</button>`;
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

  for (let hour = fold ? 7 : 1; hour < 24; hour += 1) {
    if (nowShown && Math.abs(hour * 60 - nowMinute) <= 15) continue;
    html += `<span class="cal-hour" aria-hidden="true" style="top:${scale.yOf(hour * 60)}px">${escapeHtml(formatHour(hour, tf))}</span>`;
  }

  if (nowShown) html += `<span class="cal-now-pill" aria-hidden="true" style="top:${scale.yOf(nowMinute)}px">${escapeHtml(formatMinutes(nowMinute, tf))}</span>`;

  return html;
}

function shortHour(hour, timeFormat) {
  if (timeFormat === "12h") return String(hour % 12 === 0 ? 12 : hour % 12);
  return String(hour).padStart(2, "0");
}

function column(iso, events, ctx) {
  const { scale, fold, colWidth, measureWidth, settings, strings, byId, nowDay, nowMinute, nowShown } = ctx;
  const weekday = isoWeekday(dayNumber(iso));
  let html = "";

  for (const [from, to] of offHours(settings.working_hours ? (settings.working_hours[weekday] ?? null) : undefined, scale.firstMinute)) {
    html += `<div class="cal-off" style="top:${scale.yOf(from)}px;height:${scale.yOf(to) - scale.yOf(from)}px"></div>`;
  }

  // Drafts are drawn over the column at full width, never folded into a "+N".
  const drafts = segmentsForDay(events.filter((e) => e.kind === "draft"), iso);
  let segments = segmentsForDay(events.filter((e) => e.kind !== "draft"), iso);
  if (fold) {
    const dayStart = dayNumber(iso) * MINUTES_PER_DAY;
    const isEarly = (g) => (byId.get(g.id)?.endMin ?? dayStart + g.e) - dayStart <= NIGHT_END;
    const early = segments.filter(isEarly).length;
    const time = formatMinutes(NIGHT_END, settings.time_format);
    const action = interpolate(strings.show_early_hours, { time });
    if (early) {
      const text = interpolate(strings.early_hours, { time, count: early });
      html += `<button type="button" class="cal-early" data-night-toggle aria-label="${escapeHtml(`${text}, ${action}`)}">${escapeHtml(text)}</button>`;
    } else {
      html += `<span class="cal-early is-empty" aria-hidden="true"></span>`;
    }
    segments = segments.filter((g) => !isEarly(g)).map((g) => ({ ...g, s: Math.max(g.s, NIGHT_END) }));
  }

  const laid = layoutColumn(segments, {
    colWidth: colWidth - 6,
    hourHeight: scale.hourHeight,
    yOf: scale.yOf,
    measureLines: (text, w) => countLines(text, w, measureWidth),
  });

  // Layout stacking doubled, so one odd level between the events and the chip
  // above them is free for a narrow event widened on hover (--cal-lift).
  const lift = 2 * Math.max(0, ...laid.map((item) => (item.chip ? item.z : item.z + 1))) - 1;
  for (const item of laid) html += item.chip ? chip(item, byId, strings) : eventBlock(item, byId.get(item.id), ctx);
  for (const segment of drafts) html += draftBlock(segment, byId.get(segment.id), ctx, lift + 2);
  if (nowShown && iso === nowDay) html += `<div class="cal-now" style="top:${scale.yOf(nowMinute)}px" aria-hidden="true"></div>`;

  return `<div class="cal-col${weekday > 5 ? " is-weekend" : ""}" data-day="${iso}" style="--cal-col:${colWidth}px;--cal-lift:${lift}">${html}</div>`;
}

function offHours(hours, first) {
  if (hours === undefined) return [];
  if (!hours) return [[first, MINUTES_PER_DAY]];
  const [start, end] = hours;
  const out = [];
  if (start > first) out.push([first, start]);
  if (end < MINUTES_PER_DAY) out.push([Math.max(end, first), MINUTES_PER_DAY]);
  return out;
}

// How many title lines fit, and whether the time line still does. A title
// that wants more lines than fit above the time line keeps them and drops the
// time, which the block's position on the axis already tells; nothing is ever
// drawn taller than the block, so no line is cut through.
function textFit(item, title, wantsTime, measureWidth) {
  const inner = item.height - EVENT_CHROME;
  const cap = item.lineClamp ?? 4;
  const wanted = Math.min(cap, countLines(title, Math.max(1, item.width - TITLE_INSET), measureWidth));
  const withTime = Math.max(1, Math.floor((inner - TIME_LINE - (item.timeGap || 0)) / LINE_HEIGHT));
  const without = Math.max(1, Math.floor(inner / LINE_HEIGHT));
  if (!wantsTime) return { lines: Math.min(cap, without), time: false };
  if (wanted <= withTime || without <= withTime) return { lines: Math.min(cap, withTime), time: true };
  return { lines: Math.min(wanted, without), time: false };
}

// Whether a one-row block keeps its start time beside the title: only while
// the title keeps enough room to be recognised, or all the room it needs.
function shortRowFits(item, title, time, measureWidth) {
  const room = item.width - TITLE_INSET - SHORT_GAP - measureWidth(time) * TIME_SCALE;
  return room >= Math.min(SHORT_TITLE_ROOM, measureWidth(title));
}

// The title, with every word too wide for its line marked to truncate on a
// line of its own (`.cal-ev-word`) instead of breaking mid-word.
function titleHtml(title, width, measureWidth) {
  return String(title ?? "")
    .split(/(\s+)/)
    .map((part) => (part.trim() && isLongWord(part, width, measureWidth) ? `<span class="cal-ev-word">${escapeHtml(part)}</span>` : escapeHtml(part)))
    .join("");
}

function eventBlock(item, event, { strings, settings, now, measureWidth, movingId }) {
  const editable = draggable(event);
  const tf = settings.time_format;
  const short = item.height < 38;
  const past = event.endMin <= now;
  const start = formatMinutes(event.startMin % MINUTES_PER_DAY, tf);
  const range = `${start}–${formatMinutes(event.endMin % MINUTES_PER_DAY, tf)}`;
  const fit = short ? null : textFit(item, event.title, !item.hideTime, measureWidth);
  const shortWithoutTime = short && !shortRowFits(item, event.title, start, measureWidth);
  const time = item.hideTime || shortWithoutTime || (fit && !fit.time) ? "" : short || item.width < 110 ? start : range;
  const tiny = short && item.height < LINE_HEIGHT + 4;
  const classes = ["cal-ev", short && "is-short", tiny && "is-tiny", item.width < 92 && "is-narrow", past && "is-past", event.free && "is-free", event.kind === "booking" && "is-booking", event.attention && "is-attention", movingId === event.id && "is-moving"]
    .filter(Boolean)
    .join(" ");
  const label = [event.title, dateLabel(isoFromDay(event.startDay), strings), range, event.free && strings.shown_as_free, past && strings.ended, event.attention && strings.waiting_to_sync]
    .filter(Boolean)
    .join(", ");
  const style =
    `top:${item.top}px;height:${item.height}px;--l:${item.left + 1}px;--w:${Math.max(item.width - 3, 12)}px;--z:${2 * item.z};--cal-ev:${colour(event.colour)}` +
    (fit ? `;--cal-lines:${fit.lines}` : "") +
    (tiny ? `;--cal-lh:${Math.max(8, Math.floor(item.height - 2))}px` : "");
  const timeHtml = time ? `<span class="cal-ev-time"${item.timeGap ? ` style="margin-top:${Math.round(item.timeGap)}px"` : ""}>${escapeHtml(time)}</span>` : "";

  // tabindex -1: the hook makes one block the grid's only tab stop and the
  // arrow keys move between them.
  return (
    `<div class="${classes}" role="button" tabindex="-1" data-event-id="${escapeHtml(event.id)}"${editable ? " data-editable" : ""} aria-label="${escapeHtml(label)}" aria-describedby="calendar-keys-hint" style="${style}">` +
    `<span class="cal-ev-title">${short ? escapeHtml(event.title) : titleHtml(event.title, item.width - TITLE_INSET, measureWidth)}</span>${timeHtml}` +
    (event.attention ? `<span class="cal-ev-dot" aria-hidden="true"></span>` : "") +
    (editable && item.height >= GRIP_MIN_HEIGHT ? GRIPS : "") +
    `</div>`
  );
}

// The draft quick create is editing, or one waiting for the server. Not a
// control: the quick-create popover is its accessible form, so the block is
// hidden from assistive technology and carries no event id.
function draftBlock(segment, event, { strings, settings, scale, colWidth }, z) {
  const tf = settings.time_format;
  const top = scale.yOf(Math.max(segment.s, scale.firstMinute));
  const height = Math.max(scale.yOf(Math.max(segment.e, scale.firstMinute)) - top, 12);
  const time = `${formatMinutes(event.startMin % MINUTES_PER_DAY, tf)}–${formatMinutes(event.endMin % MINUTES_PER_DAY, tf)}`;
  const classes = ["cal-ev", "is-draft", event.pending && "is-pending", event.free && "is-free", height < 38 && "is-short"].filter(Boolean).join(" ");
  return (
    `<div class="${classes}" data-draft-id="${escapeHtml(event.id)}" aria-hidden="true" style="top:${top}px;height:${height}px;--l:1px;--w:${Math.max(colWidth - 9, 12)}px;--z:${z};--cal-ev:${colour(event.colour)}">` +
    `<span class="cal-ev-title">${escapeHtml(event.title || strings.new_event)}</span>` +
    `<span class="cal-ev-time">${escapeHtml(time)}</span>` +
    (event.pending ? `<span class="cal-ev-saving">${escapeHtml(strings.saving_draft)}</span>` : "") +
    `</div>`
  );
}

function draftBar(bar, event, strings) {
  const classes = ["cal-adbar", "is-draft", event.pending && "is-pending", bar.cutStart && "cut-start", bar.cutEnd && "cut-end"].filter(Boolean).join(" ");
  return (
    `<div class="${classes}" data-draft-id="${escapeHtml(event.id)}" aria-hidden="true" style="grid-column:${bar.startIndex + 2} / ${bar.endIndex + 3};grid-row:${bar.lane + 1};--cal-ev:${colour(event.colour)}">` +
    `${escapeHtml(event.title || strings.new_event)}${event.pending ? ` <span class="cal-ev-saving">${escapeHtml(strings.saving_draft)}</span>` : ""}</div>`
  );
}

function chip(item, byId, strings) {
  const titles = item.hidden.map((id) => byId.get(id)?.title).filter(Boolean).join(", ");
  const label = interpolate(strings.also_here, { titles }) + (item.warn ? `, ${strings.waiting_to_sync}` : "");
  return (
    `<button type="button" class="cal-more${item.warn ? " is-warn" : ""}" data-more="${escapeHtml(item.ids.join(","))}" data-hidden="${escapeHtml(item.hidden.join(","))}" ` +
    `aria-label="${escapeHtml(label)}" style="top:${item.top}px;height:${item.height}px;--l:${item.left + 1}px;--w:${item.width - 2}px;--z:${2 * item.z}">` +
    `+${item.hidden.length}<small>${escapeHtml(strings.more)}</small>` +
    (item.warn ? `<span class="cal-more-dot" aria-hidden="true"></span>` : "") +
    `</button>`
  );
}

export function renderSkeleton(days, strings) {
  const columns = days
    .map(() => `<div class="cal-skeleton-col"><span class="cal-skeleton-block"></span><span class="cal-skeleton-block is-short"></span></div>`)
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
