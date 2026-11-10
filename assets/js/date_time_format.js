/**
 * The date and time arithmetic behind `<.date_picker>` and `<.time_picker>`:
 * reading what a visitor types, and writing a value the way the server does.
 * Values are always ISO (`YYYY-MM-DD`, `HH:MM`); only the text a person reads
 * or types varies with their language and clock.
 */

const pad = (number) => String(number).padStart(2, "0");

/** @returns {string} `YYYY-MM-DD` for local calendar fields. */
export const isoDate = (year, month, day) => `${String(year).padStart(4, "0")}-${pad(month)}-${pad(day)}`;

/** @returns {{year: number, month: number, day: number}|null} */
export function parseIso(iso) {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || "");
  if (!match) return null;

  const [year, month, day] = match.slice(1).map(Number);
  return realDate(year, month, day);
}

function realDate(year, month, day) {
  const date = new Date(Date.UTC(year, month - 1, day));

  // `setUTCFullYear` because `Date.UTC` reads years below 100 as 19xx.
  date.setUTCFullYear(year);

  if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return null;
  return { year, month, day };
}

/** Adds `days` to an ISO date, crossing months and years. */
export function addDays(iso, days) {
  const { year, month, day } = parseIso(iso);
  const date = new Date(Date.UTC(year, month - 1, day + days));

  date.setUTCFullYear(year + (date.getUTCFullYear() - year));
  return isoDate(date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate());
}

/**
 * Moves an ISO date by whole months, keeping the day where the target month
 * has it (31 March back a month is 28 February, as a calendar reads it).
 */
export function addMonths(iso, months) {
  const { year, month, day } = parseIso(iso);
  const index = year * 12 + (month - 1) + months;
  const targetYear = Math.floor(index / 12);
  const targetMonth = index - targetYear * 12 + 1;
  const lastDay = new Date(Date.UTC(targetYear, targetMonth, 0)).getUTCDate();

  return isoDate(targetYear, targetMonth, Math.min(day, lastDay));
}

/** 0 is Sunday; `Date.getUTCDay`'s numbering. */
const weekdayOf = (iso) => {
  const { year, month, day } = parseIso(iso);
  return new Date(Date.UTC(year, month - 1, day)).getUTCDay();
};

/** The ISO date beginning the week `iso` falls in. */
export function startOfWeek(iso, weekStart) {
  return addDays(iso, -((weekdayOf(iso) - weekStart + 7) % 7));
}

/** The ISO date ending the week `iso` falls in. */
export const endOfWeek = (iso, weekStart) => addDays(startOfWeek(iso, weekStart), 6);

/**
 * 42 consecutive ISO dates: the six full weeks that hold the first of the
 * month, as `PreferenceHelpers.month_matrix/2` lays out the mini month.
 */
export function monthMatrix(year, month, weekStart) {
  const start = startOfWeek(isoDate(year, month, 1), weekStart);

  return Array.from({ length: 42 }, (_unused, index) => addDays(start, index));
}

/** A date in the server's short format, from `datePattern` in the picker's config. */
export function formatDate(iso, { datePattern, shortMonths }) {
  const date = parseIso(iso);
  if (!date) return "";

  return datePattern
    .replace("{d}", String(date.day))
    .replace("{m}", shortMonths[date.month - 1])
    .replace("{y}", String(date.year));
}

/** A time as `TimeFormat.format/2` writes it. */
export function formatTime(value, timeFormat) {
  const match = /^(\d{2}):(\d{2})/.exec(value || "");
  if (!match) return "";

  const [hours, minutes] = [Number(match[1]), match[2]];
  if (timeFormat !== "12h") return `${pad(hours)}:${minutes}`;

  return `${hours % 12 === 0 ? 12 : hours % 12}:${minutes} ${hours < 12 ? "AM" : "PM"}`;
}

const normaliseMonth = (name) => name.trim().toLowerCase().replace(/\.$/, "");

const monthFromWord = (word, { shortMonths, longMonths }) => {
  const needle = normaliseMonth(word);

  if (needle.length < 3) return null;

  const matches = (names) =>
    names.findIndex((name) => {
      const known = normaliseMonth(name);
      return known === needle || (needle.length >= 3 && known.startsWith(needle));
    });

  const index = [matches(longMonths), matches(shortMonths)].find((found) => found >= 0);
  return index === undefined ? null : index + 1;
};

const fullYear = (text) => {
  const year = Number(text);
  return text.length <= 2 ? 2000 + year : year;
};

/**
 * What a typed date means: the ISO date, `""` for a cleared field, or `null`
 * for something it cannot read. It takes the field's own short format and the
 * year-first and day-first numeric forms; every Tymeslot language writes the
 * day before the month, so the numeric reading follows that, and a year left
 * out means this one.
 */
export function parseDate(text, config, today = new Date()) {
  const raw = text.trim().toLowerCase();

  if (raw === "") return "";

  const tokens = raw.split(/[\s,./-]+/).filter((token) => token !== "");
  const numbers = tokens.filter((token) => /^\d+$/.test(token));
  const words = tokens.filter((token) => !/^\d+$/.test(token));
  const month = words.map((word) => monthFromWord(word, config)).find((found) => found);

  if (month) {
    const [day, year = String(today.getFullYear())] = numbers;
    return realIso(fullYear(year), month, Number(day));
  }

  if (numbers.length < 2 || numbers.length > 3 || words.length > 0) return null;

  // A first group of four digits is the ISO order, year first.
  if (numbers[0].length === 4) {
    return numbers.length === 3 ? realIso(Number(numbers[0]), Number(numbers[1]), Number(numbers[2])) : null;
  }

  const [day, monthNumber, year = String(today.getFullYear())] = numbers;
  return realIso(fullYear(year), Number(monthNumber), Number(day));
}

const realIso = (year, month, day) => {
  if (!Number.isInteger(day) || year < 1000 || year > 9999) return null;

  const date = realDate(year, month, day);
  return date ? isoDate(date.year, date.month, date.day) : null;
};

/**
 * What a typed time means: `HH:MM`, `""` for a cleared field, or `null`.
 * Takes either clock whatever the field shows: `14:30`, `1430`, `2.30 pm`,
 * `2pm`, `14`.
 */
export function parseTime(text) {
  const raw = text.trim().toLowerCase().replace(/\s+/g, "");

  if (raw === "") return "";

  const match = /^(\d{1,2})(?:[:.h]?(\d{2}))?([ap])?\.?(?:m\.?)?$/.exec(raw);
  if (!match) return null;

  let hours = Number(match[1]);
  const minutes = match[2] === undefined ? 0 : Number(match[2]);
  const meridiem = match[3];

  if (minutes > 59) return null;

  if (meridiem) {
    if (hours < 1 || hours > 12) return null;
    hours = (hours % 12) + (meridiem === "p" ? 12 : 0);
  } else if (hours > 23) {
    return null;
  }

  return `${pad(hours)}:${pad(minutes)}`;
}

/** Today's ISO date on the visitor's own calendar. */
export function todayIso(now = new Date()) {
  return isoDate(now.getFullYear(), now.getMonth() + 1, now.getDate());
}
