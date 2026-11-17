/**
 * Reads what the organiser typed into quick create: a title plus, when they
 * typed them, a day, a time or a range, a duration, a calendar, guests and a
 * place. Pure: the caller passes the slot the draft started from (`base`),
 * today's date and the writable calendars. The server re-validates every
 * field on save (Tymeslot.CalendarGrid.CreateParams), so nothing here is
 * trusted.
 *
 * Grammar (English words; numeric dates are always day first, never month
 * first):
 *  - a day: today, tonight, tomorrow (tmrw, tmr), a weekday ("fri", "next
 *    friday", "on monday"), "17 oct", "oct 17", "17 october 2026",
 *    "17/10", "17/10/2026", "17.10.", "17.10.2026", ISO "2026-10-17". A
 *    date without a year that would be more than 30 days ago is next year's.
 *    A date that does not exist (31 feb) is not read and stays in the title.
 *    A weekday is the next one on or after today; "next" only matters when
 *    it names today's weekday.
 *  - a span of days: two days in a row, with or without a hyphen, en dash, em dash, "to",
 *    "until" or "till" between them ("sat sun", "fri-sun", "20-22 oct"). All
 *    day across them unless a time is given.
 *  - a time: "14:00", "14.30", "2pm", "2:30 p.m.", "noon", "midnight",
 *    "at 2" (a bare hour from 1 to 6 with no leading zero is the afternoon, so
 *    14:00, as in Google Calendar; "02:00" and "2am" stay in the morning).
 *  - a range: "14:00-15:30", "2-3pm", "10am to noon", "9-17",
 *    "from 9 to 5", "22:00-02:00" (ends the next day). An end without am or
 *    pm that reads as a 12-hour clock ("2", "2:00", not "02:00" or "14:00")
 *    and would fall before the start moves to the afternoon, unless either
 *    side is written as a 24-hour time (13:00 or later, or 00:xx).
 *  - a duration: "for 45m", "30-minute", "1,5h", "1.5 hours", "1h30",
 *    "an hour", "half an hour".
 *  - "all day".
 *  - `/name`: the first writable calendar whose name starts with it; an
 *    unknown one stays in the title.
 *  - `@person@example.com`: a guest. Guests need an address; a bare `@anna`
 *    stays in the title as typed.
 *  - `;place`: up to the next `;`, `/` or `@` word, or the end. A day or time
 *    typed at the end of the place is still read ("coffee ;Nero 3pm").
 *  - text in double quotes is only ever title ("\"Sunday roast\" prep").
 *
 * Full weekday names are read wherever they stand ("Sunday roast prep" is on
 * Sunday, titled "Roast prep"); abbreviations ("sat", "sun", "wed") only
 * when a day, a time, punctuation or the end follows, so "Sat nav repair"
 * keeps its title. The first day expression wins; later ones stay in the
 * title. A typed time beats "all day".
 */
import { MINUTES_PER_DAY, dayNumber, formatWall, isoFromDay, isoWeekday } from "./time.js";

const ROLLOVER_DAYS = 30;
const YEARS = [1900, 2200];
const MARK = "\uE002"; // stands where a consumed token was
const QUOTE_OPEN = "\uE000";
const QUOTE_CLOSE = "\uE001";

const B = "(?<![\\p{L}\\d./:£€$-])"; // not inside a word, a number or a date
const E = "(?![\\p{L}\\d])";
const MONTH = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\\.?";
const ORD = "(?:st|nd|rd|th)?";
const ON = "(?:on\\s+)?";
const FULL_WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"];
const WEEKDAY = "(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues|tue|weds|wed|thurs|thur|thu|fri|sat|sun)";
const AMPM = "(am|pm|a\\.m\\.|p\\.m\\.)";
const SIDE = `(noon|midday|midnight|(\\d{1,2})(?:[:.](\\d{2})(?!\\.\\d))?\\s*${AMPM}?)`;
const DASH = "(?:-|–|—|to|until|till)";

// What may follow an abbreviated weekday for it to count as a day.
const FOLLOW = new RegExp(
  `^\\s*(?:$|[,.;!?)]|\\d|[-–—]|(?:at|from|for|on|to|until|till|noon|midday|midnight|all[- ]?day|today|tonight|tomorrow|tmrw|tmr|next|${WEEKDAY.slice(1, -1)})(?![\\p{L}]))`,
  "iu",
);

const pad = (n) => String(n).padStart(2, "0");

function monthIndex(word) {
  return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].indexOf(word.slice(0, 3).toLowerCase());
}

// A day number for year/month/day, or null when the date does not exist.
function validDay(year, month, day) {
  if (year < YEARS[0] || year > YEARS[1] || month < 1 || month > 12 || day < 1) return null;
  const date = new Date(Date.UTC(year, month - 1, day));
  if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return dayNumber(`${year}-${pad(month)}-${pad(day)}`);
}

// A date typed without a year: this year's, or next year's when this year's
// is more than ROLLOVER_DAYS ago, or when it would fall before `after`.
function dayWithoutYear(month, day, today, after) {
  const year = new Date(today * 86_400_000).getUTCFullYear();
  let found = validDay(year, month, day);
  if (found !== null && (found < today - ROLLOVER_DAYS || (after !== undefined && found < after))) found = validDay(year + 1, month, day);
  return found;
}

function fullYear(text) {
  if (!text) return null;
  return text.length === 2 ? 2000 + Number(text) : Number(text);
}

function dated(month, day, yearText, ctx, after) {
  const year = fullYear(yearText);
  return year === null ? dayWithoutYear(month, day, ctx.today, after) : validDay(year, month, day);
}

function weekdayFrom(word, next, from) {
  const target = FULL_WEEKDAYS.findIndex((name) => name.startsWith(word.slice(0, 3).toLowerCase())) + 1;
  let diff = (target - isoWeekday(from) + 7) % 7;
  if (diff === 0 && next) diff = 7;
  return from + diff;
}

// Single days. `read(match, ctx, after)` returns a day number or null;
// `after` is set when reading the second day of a span.
const SINGLE_DAYS = [
  {
    source: `${B}(today|tonight|tomorrow|tmrw|tmr)${E}`,
    read: (m, ctx) => (/^(today|tonight)$/i.test(m[1]) ? ctx.today : ctx.today + 1),
  },
  {
    source: `${B}(?<!\\b(?:every|each)\\s+)(?:(on)\\s+)?(?:(next)\\s+)?${WEEKDAY}${E}`,
    read: (m, ctx, after) => weekdayFrom(m[3], !!m[2] || after !== undefined, after ?? ctx.today),
    abbreviated: (m) => !m[1] && !m[2] && !FULL_WEEKDAYS.includes(m[3].toLowerCase()),
  },
  {
    source: `${B}${ON}(\\d{1,2})${ORD}\\s+${MONTH}(?:\\s+(\\d{4}))?${E}`,
    read: (m, ctx, after) => dated(monthIndex(m[2]) + 1, Number(m[1]), m[3], ctx, after),
  },
  {
    source: `${B}${ON}${MONTH}\\s+(\\d{1,2})${ORD}(?:,?\\s+(\\d{4}))?${E}`,
    read: (m, ctx, after) => dated(monthIndex(m[1]) + 1, Number(m[2]), m[3], ctx, after),
  },
  {
    source: `${B}${ON}(\\d{4})-(\\d{2})-(\\d{2})${E}`,
    read: (m) => validDay(Number(m[1]), Number(m[2]), Number(m[3])),
  },
  {
    source: `${B}${ON}(\\d{1,2})\\/(\\d{1,2})(?:\\/(\\d{4}|\\d{2}))?(?![\\p{L}\\d/])`,
    read: (m, ctx, after) => dated(Number(m[2]), Number(m[1]), m[3], ctx, after),
  },
  {
    source: `${B}${ON}(\\d{1,2})\\.(\\d{1,2})\\.(\\d{4}|\\d{2})?${E}`,
    read: (m, ctx, after) => dated(Number(m[2]), Number(m[1]), m[3], ctx, after),
  },
].map((p) => ({ ...p, global: new RegExp(p.source, "giu"), anchored: new RegExp(`^(?:${p.source})`, "iu") }));

// "20-22 oct": a span written once.
const DAY_RANGE = new RegExp(`${B}${ON}(\\d{1,2})${ORD}\\s*[-–—]\\s*(\\d{1,2})${ORD}\\s+${MONTH}(?:\\s+(\\d{4}))?${E}`, "giu");
const SPAN_JOIN = /^\s*(?:[-–—]|(?:to|until|till)(?![\p{L}]))?\s*/iu;

function readSingle(pattern, m, ctx, after, rest, dashed = false) {
  const day = pattern.read(m, ctx, after);
  if (day === null || Number.isNaN(day)) return null;
  if (!dashed && pattern.abbreviated?.(m) && !FOLLOW.test(rest)) return null;
  return day;
}

// The first day expression in `t`, extended to a span when a second day
// follows it: `{index, length, first, last}` (day numbers, `last` inclusive).
function findDays(t, ctx) {
  let best = null;
  const consider = (index, length, first, last) => {
    if (!best || index < best.index || (index === best.index && length > best.length)) best = { index, length, first, last };
  };

  for (const m of t.matchAll(DAY_RANGE)) {
    const month = monthIndex(m[3]) + 1;
    const first = dated(month, Number(m[1]), m[4], ctx);
    const last = first === null ? null : validDay(new Date(first * 86_400_000).getUTCFullYear(), month, Number(m[2]));
    if (first !== null && last !== null && last >= first) {
      consider(m.index, m[0].length, first, last);
      break;
    }
  }

  for (const pattern of SINGLE_DAYS) {
    for (const m of t.matchAll(pattern.global)) {
      const day = readSingle(pattern, m, ctx, undefined, t.slice(m.index + m[0].length));
      if (day === null) continue;
      consider(m.index, m[0].length, day, day);
      break;
    }
  }

  if (best && best.first === best.last) extendSpan(t, best, ctx);
  return best;
}

function extendSpan(t, found, ctx) {
  const after = t.slice(found.index + found.length);
  const join = after.match(SPAN_JOIN)[0];
  const rest = after.slice(join.length);
  for (const pattern of SINGLE_DAYS) {
    const m = rest.match(pattern.anchored);
    if (!m) continue;
    const day = readSingle(pattern, m, ctx, found.first, rest.slice(m[0].length), join.trim() !== "");
    if (day === null || day <= found.first) continue;
    found.last = day;
    found.length += join.length + m[0].length;
    return;
  }
}

// One side of a time range, or a single time.
function side(word, hourText, minuteText, ampm, raw = false) {
  if (word && /^(noon|midday)$/i.test(word)) return { minute: 720, word: true };
  if (word && /^midnight$/i.test(word)) return { minute: 0, word: true, midnight: true };
  let hour = Number(hourText);
  const minute = minuteText === undefined ? 0 : Number(minuteText);
  if (minute > 59) return null;
  if (ampm) {
    if (hour < 1 || hour > 12) return null;
    hour = (hour % 12) + (/^p/i.test(ampm) ? 12 : 0);
  } else if (hour > 23) {
    return null;
  } else if (!raw && hour >= 1 && hour <= 6 && !/^0/.test(hourText)) {
    hour += 12; // a bare 1 to 6 reads as the afternoon, as Google Calendar does
  }
  return { minute: hour * 60 + minute, hourText, hasMinutes: minuteText !== undefined, ampm: ampm || null };
}

const is24 = (s) => !s.word && !s.ampm && (Number(s.hourText) >= 13 || /^0/.test(s.hourText));
const looks12 = (s) => !s.word && !s.ampm && Number(s.hourText) >= 1 && Number(s.hourText) <= 12 && !/^0/.test(s.hourText);

const RANGE = new RegExp(`${B}(?:(from)\\s+)?${SIDE}\\s*${DASH}\\s*${SIDE}${E}`, "giu");

// `{start, end, endRaw}` minutes from the start day's midnight; `end` has
// moved past midnight when the range runs overnight, `endRaw` has not.
function readRange(m) {
  const [, from, w1, h1, m1, a1, w2, h2, m2, a2] = m;
  const word1 = /^(noon|midday|midnight)$/i.test(w1) ? w1 : null;
  const word2 = /^(noon|midday|midnight)$/i.test(w2) ? w2 : null;
  const bare = !word1 && !word2 && m1 === undefined && m2 === undefined && !a1 && !a2;
  if (bare && !from && Number(h1) < 13 && Number(h2) < 13) return null;

  const b = side(word2, h2, m2, a2, true);
  if (!b) return null;
  let a = side(word1, h1, m1, a1);
  // "2-3pm": the start takes the end's am or pm when that keeps it earlier.
  if (a && !word1 && !a1 && a2) {
    const inherited = side(null, h1, m1, a2);
    if (inherited && inherited.minute < b.minute) a = inherited;
  }
  if (!a) return null;

  let end = b.midnight ? MINUTES_PER_DAY : b.minute;
  if (end <= a.minute && looks12(b) && !is24(a) && !is24(b)) end += 720;
  const endRaw = end;
  if (end <= a.minute) end += MINUTES_PER_DAY;
  return { start: a.minute, end, endRaw };
}

const SINGLE_TIMES = [
  { re: new RegExp(`${B}(?:at\\s+)?(\\d{1,2})[:.](\\d{2})\\s*${AMPM}?(?!\\.\\d)${E}`, "iu"), read: (m) => side(null, m[1], m[2], m[3]) },
  { re: new RegExp(`${B}(?:at\\s+)?(\\d{1,2})\\s*${AMPM}${E}`, "iu"), read: (m) => side(null, m[1], undefined, m[2]) },
  { re: new RegExp(`${B}(?:at\\s+)?(noon|midday|midnight)${E}`, "iu"), read: (m) => side(m[1]) },
  { re: new RegExp(`${B}at\\s+(\\d{1,2})(?![\\p{L}\\d:./])`, "iu"), read: (m) => side(null, m[1], undefined, undefined) },
];

const DURATIONS = [
  { re: new RegExp(`${B}(?:for\\s+)?(\\d{1,2})\\s*h\\s*(\\d{1,2})\\s*(?:m|min|mins|minutes)?${E}`, "iu"), read: (m) => Number(m[1]) * 60 + Number(m[2]) },
  {
    re: new RegExp(`${B}(?:for\\s+)?(\\d+(?:[.,]\\d+)?)\\s*-?\\s*(hours?|hrs?|h|minutes?|mins?|m)${E}`, "iu"),
    read: (m) => {
      const n = Number(m[1].replace(",", "."));
      return Math.round(/^h/i.test(m[2]) ? n * 60 : n);
    },
  },
  { re: new RegExp(`${B}(?:for\\s+)?(half an hour|a half hour|an hour)${E}`, "iu"), read: (m) => (/half/i.test(m[1]) ? 30 : 60) },
];

const ALL_DAY = /(?<![\p{L}])all[- ]?day(?![\p{L}])/iu;

// Replaces the first match of `re` in `t` that `read` accepts.
function take(t, re, read) {
  const global = new RegExp(re.source, re.flags.includes("g") ? re.flags : `${re.flags}g`);
  for (const m of t.matchAll(global)) {
    const value = read(m);
    if (value === null || value === undefined) continue;
    return { value, text: `${t.slice(0, m.index)} ${MARK} ${t.slice(m.index + m[0].length)}` };
  }
  return null;
}

// Days, times, durations and "all day", taken out of `t`.
function readWhen(t, ctx) {
  const when = { days: null, range: null, start: null, duration: null, allDay: false };

  const days = findDays(t, ctx);
  if (days) {
    when.days = days;
    t = `${t.slice(0, days.index)} ${MARK} ${t.slice(days.index + days.length)}`;
  }

  const allDay = t.match(ALL_DAY);
  if (allDay) {
    when.allDay = true;
    t = t.replace(ALL_DAY, ` ${MARK} `);
  }

  const range = take(t, RANGE, readRange);
  if (range) {
    when.range = range.value;
    t = range.text;
  } else {
    for (const { re, read } of SINGLE_TIMES) {
      const single = take(t, re, (m) => read(m)?.minute ?? null);
      if (single) {
        when.start = single.value;
        t = single.text;
        break;
      }
    }
  }

  for (const { re, read } of DURATIONS) {
    const duration = take(t, re, (m) => {
      const minutes = read(m);
      return minutes > 0 ? minutes : null;
    });
    if (duration) {
      when.duration = duration.value;
      t = duration.text;
      break;
    }
  }

  when.found = !!(when.days || when.range || when.start !== null || when.duration || when.allDay);
  return { when, rest: t };
}

const LEADING = /^(?:(?:at|on|for|from)\s+|[,;:\-–—]+\s*)/i;
const TRAILING = /(?:\s+(?:at|on|for|from|with|and|to|in)|\s*[,;:\-–—]+)$/i;

function cleanTitle(text) {
  let title = text.split(MARK).join(" ").replace(/\s+/g, " ").replace(/\s+([,.!?])/g, "$1").trim();
  let previous;
  do {
    previous = title;
    title = title.replace(LEADING, "").replace(TRAILING, "").trim();
  } while (title !== previous);
  // A first word typed all in lower case gets a capital; "iPhone" keeps its own.
  return title.replace(/^(\p{Ll})([\p{Ll}'’-]*)(?=[\s,;:.!?]|$)/u, (_m, first, rest) => first.toUpperCase() + rest);
}

function isWhenOnly(text, ctx) {
  const { when, rest } = readWhen(` ${text} `, ctx);
  return when.found && cleanTitle(rest) === "";
}

const normalise = (s) =>
  s
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[\s_-]+/g, "");

function findCalendar(query, calendars) {
  const q = normalise(query);
  if (!q) return null;
  return (
    calendars.find((c) => normalise(c.name).startsWith(q)) ||
    calendars.find((c) => c.name.split(/\s+/).some((word) => normalise(word).startsWith(q))) ||
    null
  );
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/**
 * `base`: the draft before typing, `{day: "YYYY-MM-DD", startMin, length,
 * allDay, days, calendar}` (`startMin` minutes from midnight, `length` in
 * minutes, `days` how many days an all-day draft covers).
 * `opts`: `{today: "YYYY-MM-DD", calendars: [{key, name}]}`.
 *
 * Returns `{title, start, end, allDay, calendar, location, guests, found}`:
 * `start` and `end` as wall times ("2026-10-20T14:00"), or as dates with an
 * exclusive end when all day ("2026-10-20", "2026-10-21"); `found` says
 * which parts the text supplied (`date`, `time`, `calendar`, `location`,
 * `guests`).
 */
export function parseQuick(text, base, { today, calendars = [] } = {}) {
  const ctx = { today: dayNumber(today) };
  const quotes = [];
  let t = ` ${String(text ?? "")
    .replace(/["“]([^"”]*)["”]/g, (_m, inner) => {
      quotes.push(inner);
      return `${QUOTE_OPEN}${String.fromCharCode(0xe100 + quotes.length - 1)}${QUOTE_CLOSE}`;
    })
    .replace(/\s+/g, " ")} `;
  const restore = (s) => s.replace(new RegExp(`${QUOTE_OPEN}(.)${QUOTE_CLOSE}`, "g"), (_m, c) => quotes[c.charCodeAt(0) - 0xe100]);

  const found = { date: false, time: false, calendar: false, location: false, guests: false };

  const guests = [];
  t = t.replace(/(^|\s)@([^\s@;/]+@[^\s@;/]+)/g, (match, lead, address) => {
    const email = address.replace(/[.,:)]+$/, "");
    if (!EMAIL.test(email)) return match;
    if (!guests.some((g) => g.toLowerCase() === email.toLowerCase())) guests.push(email);
    return `${lead}${MARK} `;
  });
  found.guests = guests.length > 0;

  let calendar = base.calendar ?? null;
  t = t.replace(/(^|\s)\/([\p{L}\d][\p{L}\d_-]*)/u, (match, lead, query) => {
    const hit = findCalendar(query, calendars);
    if (!hit) return match;
    calendar = hit.key;
    found.calendar = true;
    return `${lead}${MARK} `;
  });

  let location = "";
  let givenBack = "";
  t = t.replace(new RegExp(`;\\s*([^;${MARK}]*?)\\s*(?=;|\\s@|\\s\\/|${MARK}|$)`), (match, place) => {
    const words = place.split(" ").filter(Boolean);
    if (!words.length) return match;
    let keep = words.length;
    for (let i = 1; i < words.length; i += 1) {
      if (isWhenOnly(words.slice(i).join(" "), ctx)) {
        keep = i;
        break;
      }
    }
    location = restore(words.slice(0, keep).join(" "));
    givenBack = words.slice(keep).join(" ");
    return ` ${MARK} `;
  });
  found.location = location !== "";
  if (givenBack) t = `${t} ${givenBack} `;

  const { when, rest } = readWhen(t, ctx);
  const title = restore(cleanTitle(rest));

  const firstDay = when.days ? when.days.first : dayNumber(base.day);
  const lastDay = when.days ? when.days.last : firstDay;
  const span = lastDay > firstDay;
  const timed = when.range !== null || when.start !== null;
  found.date = !!when.days;
  found.time = timed || when.duration !== null || when.allDay;

  let allDay;
  let start;
  let end;
  if (!timed && (when.allDay || span || (base.allDay && when.duration === null))) {
    allDay = true;
    const days = when.days || when.allDay ? lastDay - firstDay + 1 : Math.max(1, base.days || 1);
    start = isoFromDay(firstDay);
    end = isoFromDay(firstDay + days);
  } else {
    allDay = false;
    const length = when.duration ?? base.length;
    const startMin = when.range ? when.range.start : (when.start ?? base.startMin);
    const startAt = firstDay * MINUTES_PER_DAY + startMin;
    let endAt;
    if (when.range) endAt = span ? lastDay * MINUTES_PER_DAY + when.range.endRaw : firstDay * MINUTES_PER_DAY + when.range.end;
    else endAt = (span ? lastDay * MINUTES_PER_DAY + startMin : startAt) + length;
    start = formatWall(startAt);
    end = formatWall(endAt);
  }

  return { title, start, end, allDay, calendar, location, guests, found };
}
