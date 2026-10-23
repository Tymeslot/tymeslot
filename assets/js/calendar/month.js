/**
 * The month view's layout: six weeks of seven days. Each week is laid out on
 * its own: all-day and multi-day events run as bars (the all-day lane's
 * `layoutAllDay`), timed events are chips in each day they touch, and what
 * does not fit a cell goes behind a "+N".
 *
 * A cell has `maxLanes` rows under its day number. Bars take lanes first but
 * always leave one row free, so every day can still show a chip or its
 * "+N"; a day with more than fits keeps its last row for "+N", which counts
 * the hidden chips and the hidden bars covering it. Nothing that needs
 * attention (a request waiting for an answer, a pending or failed sync)
 * gives way while a plain event can: those take the chip rows first, and a
 * "+N" hiding one is marked `warn`. Drafts are left out.
 */
import { layoutAllDay } from "./allday.js";
import { MINUTES_PER_DAY, dayNumber, needsAnswer } from "./time.js";

const needsAttention = (e) => needsAnswer(e) || Boolean(e.attention);
const byStart = (a, b) => a.startMin - b.startMin || (a.id < b.id ? -1 : 1);

export function monthWeeks(days) {
  const weeks = [];
  for (let i = 0; i < days.length; i += 7) weeks.push(days.slice(i, i + 7));
  return weeks;
}

// Timed events (not `long`) touching `iso`, by start.
function timedOnDay(events, iso) {
  const start = dayNumber(iso) * MINUTES_PER_DAY;
  const end = start + MINUTES_PER_DAY;
  return events.filter((e) => !e.long && e.kind !== "draft" && e.startMin < end && Math.max(e.endMin, e.startMin + 1) > start).sort(byStart);
}

// Every event touching `iso`: all-day and multi-day first, then timed by start.
export function eventsOnDay(events, iso) {
  const day = dayNumber(iso);
  const long = events.filter((e) => e.long && e.kind !== "draft" && e.startDay <= day && e.endDay > day).sort(byStart);
  return [...long, ...timedOnDay(events, iso)];
}

export function monthLayout(weeks, events, { maxLanes }) {
  const lanes = Math.max(1, Math.floor(maxLanes));
  const byId = new Map(events.map((e) => [e.id, e]));
  const long = events.filter((e) => e.long && e.kind !== "draft");

  return weeks.map((days) => {
    const { bars } = layoutAllDay(long, days, { maxLanes: Infinity });
    const used = bars.reduce((count, bar) => Math.max(count, bar.lane + 1), 0);
    const barRows = Math.min(used, lanes - 1);
    const rows = lanes - barRows;
    const chips = {};
    const more = {};
    const warn = {};

    days.forEach((iso, i) => {
      const hiddenBars = bars.filter((bar) => bar.lane >= barRows && bar.startIndex <= i && bar.endIndex >= i).map((bar) => byId.get(bar.id));
      const timed = timedOnDay(events, iso);
      const overflow = hiddenBars.length > 0 || timed.length > rows;
      const count = overflow ? Math.min(timed.length, rows - 1) : timed.length;
      const shown = new Set([...timed].sort((a, b) => needsAttention(b) - needsAttention(a) || byStart(a, b)).slice(0, count));
      const hidden = [...hiddenBars, ...timed.filter((e) => !shown.has(e))];
      chips[iso] = timed.filter((e) => shown.has(e));
      more[iso] = hidden.length;
      warn[iso] = hidden.some(needsAttention);
    });

    return { days, bars: bars.filter((bar) => bar.lane < barRows), barRows, chips, more, warn };
  });
}

// How many 20px rows fit under a cell's 24px day number.
export function chipCapacity(cellHeight, { head = 24, row = 20 } = {}) {
  return Math.max(1, Math.floor((cellHeight - head) / row));
}

// A day's first `max` events as dots: what needs attention first. A free
// event's dot is hollow, as its block is outlined.
export function dayDots(events, iso, max = 3) {
  return eventsOnDay(events, iso)
    .sort((a, b) => needsAttention(b) - needsAttention(a))
    .slice(0, max)
    .map((e) => ({ colour: e.colour, attention: needsAttention(e), free: !!e.free && !e.expired }));
}

// The roving index after `key` in a grid of `total` days, seven to a row; a
// step off the grid stays put.
export function monthStep(index, key, total = 42) {
  const rowStart = index - (index % 7);
  const next = { ArrowLeft: index - 1, ArrowRight: index + 1, ArrowUp: index - 7, ArrowDown: index + 7, Home: rowStart, End: Math.min(rowStart + 6, total - 1) }[key];
  return next === undefined || next < 0 || next >= total ? index : next;
}
