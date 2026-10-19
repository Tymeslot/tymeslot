/**
 * The quick-create draft, as pure functions. The hook keeps one draft while
 * the organiser types (hooks/calendar_canvas/draft.js and create.js); every
 * change returns a new draft.
 *
 * A draft holds wall minutes, as time.js does: `start` and `end` (for an
 * all-day draft, midnights, `end` exclusive), plus `allDay`, `calendar` (a
 * `"<integration_id>:<calendar_id>"` key), `title`, `location`, `guests`,
 * `free`, the typed `text`, its kind (`kind`: "event" or "open", see
 * opening.js, with the opening's `meetingType` and `repeat`), where it came
 * from (`origin`: "next" for C, else null), what the text supplied
 * (`found`), `base` (the slot the text is read against, see parse.js),
 * `memory` (the last timed start and length, for switching all day off
 * again), `status` and `error`.
 *
 * Status: "editing" while quick create is open, "saving" once Save was
 * pressed, "created" once the server accepted it, "panel" once More options
 * handed it to the side panel. The last two are drawn until the server's
 * next payload, which carries the draft itself (`kind: "draft"`) or the
 * created event.
 *
 * A chip edit (date, start, end, all day, calendar) becomes the new base, so
 * typing on keeps it; a day or time typed in the field still wins the next
 * time the field changes. The end follows the start: moving the start or
 * the date keeps the length, and an end before the start means the next day.
 */
import { MIN_LENGTH, SNAP } from "./drag.js";
import { parseQuick } from "./parse.js";
import { MINUTES_PER_DAY, dayNumber, formatWall, isoFromDay, parseWall } from "./time.js";

export const DEFAULT_LENGTH = 30;
const MORNING = 9 * 60;
const LATEST_START_TODAY = 22 * 60;
const LEAD = 15; // C never starts an event sooner than this

const floorTo = (minute, step = SNAP) => Math.floor(minute / step) * step;
const ceilTo = (minute, step = SNAP) => Math.ceil(minute / step) * step;
const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
const dayOf = (minute) => Math.floor(minute / MINUTES_PER_DAY);

export function baseOf(draft) {
  const day = dayOf(draft.start);
  if (draft.allDay) {
    const days = Math.max(1, Math.round((draft.end - draft.start) / MINUTES_PER_DAY));
    return { day: isoFromDay(day), startMin: draft.memory.startMin, length: draft.memory.length, allDay: true, days, calendar: draft.calendar };
  }
  return { day: isoFromDay(day), startMin: draft.start - day * MINUTES_PER_DAY, length: draft.end - draft.start, allDay: false, days: 1, calendar: draft.calendar };
}

function remembered(draft) {
  if (draft.allDay) return draft;
  return { ...draft, memory: { startMin: draft.start - dayOf(draft.start) * MINUTES_PER_DAY, length: draft.end - draft.start } };
}

export function rebased(draft) {
  const next = remembered(draft);
  return { ...next, base: baseOf(next), error: null };
}

// A timed draft for `range` ({startMin, endMin}, wall minutes).
export function draftFromRange(id, range, calendar) {
  return rebased({
    id,
    start: range.startMin,
    end: range.endMin,
    allDay: false,
    calendar: calendar ?? null,
    title: "",
    location: "",
    guests: [],
    free: false,
    kind: "event",
    meetingType: null,
    repeat: "once",
    origin: null,
    text: "",
    found: {},
    memory: { startMin: MORNING, length: DEFAULT_LENGTH },
    status: "editing",
    error: null,
  });
}

// The range a drag from `from` to `to` (minutes within day number `day`)
// covers: snapped outwards to quarter hours, at least MIN_LENGTH long,
// inside the day and after `firstMinute` (the end of a folded night).
export function createRange(day, from, to, firstMinute = 0) {
  const lo = clamp(floorTo(Math.min(from, to)), firstMinute, MINUTES_PER_DAY - MIN_LENGTH);
  const hi = clamp(ceilTo(Math.max(from, to)), lo + MIN_LENGTH, MINUTES_PER_DAY);
  return { startMin: day * MINUTES_PER_DAY + lo, endMin: day * MINUTES_PER_DAY + hi };
}

// A click on a slot: the quarter hour under the pointer, DEFAULT_LENGTH
// long, cut at midnight.
export function draftFromSlot(id, slot, calendar, firstMinute = 0) {
  const start = clamp(floorTo(slot.minute), firstMinute, MINUTES_PER_DAY - MIN_LENGTH);
  const end = Math.min(start + DEFAULT_LENGTH, MINUTES_PER_DAY);
  return draftFromRange(id, { startMin: slot.day * MINUTES_PER_DAY + start, endMin: slot.day * MINUTES_PER_DAY + end }, calendar);
}

// `after`, a change of `before`; when its time moved, it no longer sits
// where C put it (`origin`), so C's one-time move leaves the organiser's
// own choice alone.
function retimed(before, after) {
  const moved = after.start !== before.start || after.end !== before.end || after.allDay !== before.allDay;
  return moved ? { ...after, origin: null } : after;
}

// The draft after `parseQuick` read its text.
export function applyParse(draft, parsed) {
  const next = remembered({
    ...draft,
    title: parsed.title,
    location: parsed.location,
    guests: parsed.guests,
    calendar: parsed.calendar,
    allDay: parsed.allDay,
    start: parseWall(parsed.start),
    end: parseWall(parsed.end),
    found: parsed.found,
    error: null,
  });
  return retimed(draft, next);
}

// The draft after the field changed to `text`. `opts` is parseQuick's:
// `{today, calendars}`.
export function applyText(draft, text, opts) {
  return applyParse({ ...draft, text }, parseQuick(text, draft.base, opts));
}

const TIME = /^(\d{2}):(\d{2})$/;
const DATE = /^\d{4}-\d{2}-\d{2}$/;

function minuteOf(value) {
  const m = TIME.exec(value || "");
  if (!m || Number(m[1]) > 23 || Number(m[2]) > 59) return null;
  return Number(m[1]) * 60 + Number(m[2]);
}

/**
 * The draft after a chip changed: "date" ("YYYY-MM-DD"), "start" and "end"
 * ("HH:MM", as a time input gives them), "allDay", "free" (booleans) or
 * "calendar" (a key). A value an input can produce while being cleared ("")
 * leaves the draft as it was.
 */
export function applyChip(draft, chip, value) {
  return retimed(draft, chipped(draft, chip, value));
}

function chipped(draft, chip, value) {
  const day = dayOf(draft.start);
  const length = draft.end - draft.start;

  if (chip === "free") return { ...draft, free: !!value };
  if (chip === "calendar") return value ? rebased({ ...draft, calendar: value }) : draft;

  if (chip === "date") {
    if (!DATE.test(value || "")) return draft;
    const start = dayNumber(value) * MINUTES_PER_DAY + (draft.start - day * MINUTES_PER_DAY);
    return rebased({ ...draft, start, end: start + length });
  }

  if (chip === "allDay") {
    if (!!value === draft.allDay) return draft;
    if (value) return rebased({ ...remembered(draft), allDay: true, start: day * MINUTES_PER_DAY, end: (day + 1) * MINUTES_PER_DAY });
    const start = day * MINUTES_PER_DAY + draft.memory.startMin;
    return rebased({ ...draft, allDay: false, start, end: start + draft.memory.length });
  }

  if (draft.allDay) return draft;
  const minute = minuteOf(value);
  if (minute === null) return draft;

  if (chip === "start") {
    const start = day * MINUTES_PER_DAY + minute;
    return rebased({ ...draft, start, end: start + length });
  }

  if (chip === "end") {
    let end = day * MINUTES_PER_DAY + minute;
    if (end < draft.start) end += MINUTES_PER_DAY;
    if (end === draft.start) end = draft.start + MIN_LENGTH;
    return rebased({ ...draft, end });
  }

  return draft;
}

function wallOrDate(minute, allDay) {
  return allDay ? isoFromDay(dayOf(minute)) : formatWall(minute);
}

// The params of `calendar:create` and `calendar:more_options`. An empty
// title stays empty: the server names it.
export function toPayload(draft) {
  return {
    draft: draft.id,
    title: draft.title,
    start: wallOrDate(draft.start, draft.allDay),
    end: wallOrDate(draft.end, draft.allDay),
    all_day: draft.allDay,
    calendar: draft.calendar,
    location: draft.location,
    guests: [...draft.guests],
    free: draft.free,
  };
}

// The draft as a payload event (`kind: "draft"`), drawn like the server's
// own drafts; normalise it with time.js before drawing.
export function draftEvent(draft, calendars = []) {
  const calendar = calendars.find((c) => c.key === draft.calendar);
  return {
    id: `draft-${draft.id}`,
    kind: "draft",
    title: draft.title,
    all_day: draft.allDay,
    start: wallOrDate(draft.start, draft.allDay),
    end: wallOrDate(draft.end, draft.allDay),
    colour: calendar?.colour ?? null,
    free: draft.free,
    pending: draft.status === "saving" || draft.status === "created",
    attention: false,
    editable: false,
    movable: false,
  };
}

/**
 * Where C (and the toolbar's Create) puts a new draft: `{startMin, endMin}`.
 * Today, when it is visible and before 22:00, at the next quarter hour at
 * least 15 minutes ahead; today but later, tomorrow at 09:00; otherwise at
 * 09:00 on the first visible day. From there it skips past busy timed events
 * (free ones, all-day ones and drafts do not count) until a gap of `length`
 * opens; when none opens before midnight the first candidate stands.
 * `now` is a wall minute, `days` the visible ISO days, `events` normalised,
 * `floor` the day's first visible minute (a folded night hides the rest).
 */
export function nextSlot(now, days, events, length = DEFAULT_LENGTH, floor = 0) {
  const today = dayOf(now);
  const visible = days.map(dayNumber);
  let day = visible[0];
  let first = MORNING;
  if (visible.includes(today)) {
    const minute = now - today * MINUTES_PER_DAY;
    if (minute < LATEST_START_TODAY) {
      day = today;
      first = ceilTo(minute + LEAD);
    } else {
      day = today + 1;
    }
  }

  first = Math.max(first, floor);
  const base = day * MINUTES_PER_DAY;
  const busy = events.filter((e) => !e.long && !e.free && e.kind !== "draft");
  let at = first;
  for (;;) {
    const clash = busy.find((e) => e.startMin < base + at + length && e.endMin > base + at);
    if (!clash) break;
    at = ceilTo(clash.endMin - base);
    if (at + length > MINUTES_PER_DAY) {
      at = first;
      break;
    }
  }
  return { startMin: base + at, endMin: base + at + length };
}
