/**
 * Wall-clock time maths for the calendar canvas.
 *
 * The server sends times as the organiser's wall clock ("2026-10-16T09:30"),
 * never instants. Here they become minutes since 1970-01-01T00:00 read as if
 * UTC, so every sum and comparison happens on that wall clock and the
 * browser's own zone never enters the picture. Day numbers are the same idea
 * at day resolution.
 *
 * `periodDays`, `shiftPeriod` and `viewSwitchAnchor` mirror
 * Tymeslot.CalendarGrid.Period so the hook can draw the next period before
 * the server answers: a month is the six weeks of `monthMatrix` and steps
 * by a calendar month with the day clamped; an agenda is AGENDA_DAYS days
 * from its date.
 */
export const MINUTES_PER_DAY = 1440;
export const NIGHT_END = 420; // 07:00, where the folded night strip ends
export const NIGHT_STRIP = 28; // px the folded night occupies
export const HOUR_HEIGHT = { comfortable: 52, compact: 38 };

const MS_PER_DAY = 86_400_000;
export const AGENDA_DAYS = 28;
// The furthest an agenda extends from its date before "Show later" moves it on.
export const AGENDA_MAX_DAYS = 168;
const STEP = { day: 1, three_day: 3, week: 7, agenda: AGENDA_DAYS };
const TIME_GRID = new Set(["day", "three_day", "week"]);
const pad = (n) => String(n).padStart(2, "0");

export function dayNumber(iso) {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  return Date.UTC(y, m - 1, d) / MS_PER_DAY;
}

export function isoFromDay(day) {
  const date = new Date(day * MS_PER_DAY);
  return `${date.getUTCFullYear()}-${pad(date.getUTCMonth() + 1)}-${pad(date.getUTCDate())}`;
}

export function parseWall(text) {
  const [h, m] = (text.slice(11, 16) || "00:00").split(":").map(Number);
  return dayNumber(text) * MINUTES_PER_DAY + h * 60 + m;
}

// The inverse of parseWall: a wall-clock minute as "2026-10-15T11:00".
export function formatWall(minute) {
  minute = Math.round(minute);
  const day = Math.floor(minute / MINUTES_PER_DAY);
  const rest = minute - day * MINUTES_PER_DAY;
  return `${isoFromDay(day)}T${pad(Math.floor(rest / 60))}:${pad(rest % 60)}`;
}

// 1 is Monday, 7 is Sunday, as Elixir's Date.day_of_week/1.
export function isoWeekday(day) {
  return ((new Date(day * MS_PER_DAY).getUTCDay() + 6) % 7) + 1;
}

export function addDays(iso, count) {
  return isoFromDay(dayNumber(iso) + count);
}

export function isTimeGrid(view) {
  return TIME_GRID.has(view);
}

// The day number of the week start on or before `day`.
function weekStartOf(day, weekStart) {
  const weekday = isoWeekday(day);
  return day - (weekStart === "sunday" ? weekday % 7 : weekday - 1);
}

// Six weeks of seven days covering `iso`'s month, as Period.month_matrix/2.
export function monthMatrix(iso, weekStart) {
  const first = weekStartOf(dayNumber(`${iso.slice(0, 7)}-01`), weekStart);
  return Array.from({ length: 42 }, (_, k) => isoFromDay(first + k));
}

export function periodDays(view, iso, weekStart, showWeekends) {
  const day = dayNumber(iso);
  if (view === "day") return [isoFromDay(day)];
  if (view === "three_day") return [0, 1, 2].map((k) => isoFromDay(day + k));
  if (view === "month") return monthMatrix(iso, weekStart);
  if (view === "agenda") return Array.from({ length: AGENDA_DAYS }, (_, k) => isoFromDay(day + k));

  const first = weekStartOf(day, weekStart);

  return [0, 1, 2, 3, 4, 5, 6]
    .map((k) => first + k)
    .filter((d) => showWeekends || isoWeekday(d) < 6)
    .map(isoFromDay);
}

// The date another view opens at, switching from `view` at `iso`, as
// Period.view_switch_anchor/4: a week or a month hands over `today` when it is
// one of its days (a month's own, not its grid's neighbours), else its first
// day; the other views keep their date.
export function viewSwitchAnchor(view, iso, today, weekStart) {
  let first;
  let last;
  if (view === "week") {
    first = weekStartOf(dayNumber(iso), weekStart);
    last = first + 6;
  } else if (view === "month") {
    const [year, month] = iso.slice(0, 7).split("-").map(Number);
    first = dayNumber(`${iso.slice(0, 7)}-01`);
    last = first + new Date(Date.UTC(year, month, 0)).getUTCDate() - 1;
  } else {
    return iso;
  }
  const day = dayNumber(today);
  return day >= first && day <= last ? today : isoFromDay(first);
}

// A calendar month on, keeping the day where the month has it, else its last
// day, as Elixir's Date.shift/2 does.
function shiftMonth(iso, direction) {
  const [year, month, day] = iso.slice(0, 10).split("-").map(Number);
  const index = year * 12 + (month - 1) + direction;
  const toYear = Math.floor(index / 12);
  const toMonth = index % 12;
  const last = new Date(Date.UTC(toYear, toMonth + 1, 0)).getUTCDate();
  return `${toYear}-${pad(toMonth + 1)}-${pad(Math.min(day, last))}`;
}

export function shiftPeriod(view, iso, direction) {
  if (view === "month") return shiftMonth(iso, direction);
  return addDays(iso, direction * STEP[view]);
}

/**
 * Vertical scale of the time grid. Folded, everything before 07:00 shares one
 * strip of NIGHT_STRIP pixels and the hours start below it.
 */
export function makeScale(hourHeight, foldNight) {
  const yOf = (minute) =>
    foldNight
      ? minute <= NIGHT_END
        ? (minute / NIGHT_END) * NIGHT_STRIP
        : NIGHT_STRIP + ((minute - NIGHT_END) / 60) * hourHeight
      : (minute / 60) * hourHeight;

  // The minute at `y` pixels from the day's top, within the day.
  const minuteOf = (y) => {
    const minute = foldNight
      ? y <= NIGHT_STRIP
        ? (y / NIGHT_STRIP) * NIGHT_END
        : NIGHT_END + ((y - NIGHT_STRIP) / hourHeight) * 60
      : (y / hourHeight) * 60;
    return Math.min(MINUTES_PER_DAY, Math.max(0, minute));
  };

  return { hourHeight, foldNight, firstMinute: foldNight ? NIGHT_END : 0, yOf, minuteOf, height: yOf(MINUTES_PER_DAY) };
}

export function formatMinutes(minute, timeFormat) {
  minute = Math.round(minute);
  const h = Math.floor(minute / 60) % 24;
  const m = minute % 60;
  if (timeFormat === "12h") return `${h % 12 === 0 ? 12 : h % 12}:${pad(m)} ${h < 12 ? "AM" : "PM"}`;
  return `${pad(h)}:${pad(m)}`;
}

export function formatHour(hour, timeFormat) {
  hour %= 24;
  if (timeFormat === "12h") return `${hour % 12 === 0 ? 12 : hour % 12} ${hour < 12 ? "AM" : "PM"}`;
  return `${pad(hour)}:00`;
}

/**
 * Adds minute and day bounds to a payload event. `long` events (all-day, or
 * timed and a day or more) belong to the all-day lane, not the time grid.
 */
export function normaliseEvent(raw) {
  if (raw.all_day) {
    const startDay = dayNumber(raw.start);
    const endDay = Math.max(dayNumber(raw.end), startDay + 1);
    return { ...raw, startDay, endDay, startMin: startDay * MINUTES_PER_DAY, endMin: endDay * MINUTES_PER_DAY, long: true };
  }

  const startMin = parseWall(raw.start);
  const endMin = Math.max(parseWall(raw.end), startMin);

  return {
    ...raw,
    startMin,
    endMin,
    startDay: Math.floor(startMin / MINUTES_PER_DAY),
    endDay: Math.ceil(Math.max(endMin, startMin + 1) / MINUTES_PER_DAY),
    long: endMin - startMin >= MINUTES_PER_DAY,
  };
}

/**
 * Whether `event` is a booking request still waiting for the organiser's
 * answer: one that expired unanswered (`expired`) waits for nothing.
 */
export function needsAnswer(event) {
  return Boolean(event.request) && !event.expired;
}

/**
 * The part of each timed event that falls on `iso`, as minutes from that
 * day's midnight. Every segment is drawn at least fifteen minutes tall so it
 * can be seen and clicked, ending by midnight at the latest. `attention`
 * (kept out of "+N" first, see layout.js) covers a pending or failed sync
 * and a request waiting for an answer.
 */
export function segmentsForDay(events, iso) {
  const start = dayNumber(iso) * MINUTES_PER_DAY;
  const end = start + MINUTES_PER_DAY;

  return events
    .filter((e) => !e.long && e.startMin < end && Math.max(e.endMin, e.startMin + 1) > start)
    .map((e) => {
      const s = Math.max(e.startMin, start) - start;
      const finish = Math.min(e.endMin, end) - start;
      return { id: e.id, title: e.title, attention: !!e.attention || needsAnswer(e), s, e: Math.min(MINUTES_PER_DAY, Math.max(finish, s + 15)) };
    });
}
