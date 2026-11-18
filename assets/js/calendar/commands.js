/**
 * The command bar's own rows (hooks/calendar_canvas/command.js): the
 * registry of commands and how a query matches it, the "Go to" row for a
 * typed date and the "Add" row for a typed event, both read with quick
 * create's parser (parse.js). Pure. Labels come from `strings`
 * (PowerStrings); the settings the server pushes decide which way a toggle
 * points and which sets exist.
 *
 * A command is `{id, label, keys, keywords?, run, wideOnly?, notPhone?}`: `label` is a key in
 * `strings`, or, for a toggle that names the choice it switches to, a
 * function of the settings returning one; `run` likewise. `run.type` is
 * what the hook does: view, create, bookable, push (to the surface), key
 * (the power key table: T, J, K, F, ? and the digits, so a command does what
 * its key does) or permission (ask the browser for notifications, then push
 * its answer).
 */
import { parseQuick } from "./parse.js";
import { dateLabel, interpolate } from "./render.js";
import { MINUTES_PER_DAY, formatMinutes, parseWall } from "./time.js";

const FOLDED = { "ł": "l", "ø": "o", "đ": "d", "ß": "ss" };

// At most this many commands follow a typed query.
const MAX_COMMANDS = 6;
// What the bar offers before anything is typed; the sets go before the shortcuts.
const EMPTY_HEAD = ["today", "create", "view-day", "view-three_day", "view-week", "view-month", "view-agenda"];
// The slot parseQuick reads a line against: today at 09:00, half an hour.
const BASE_START = 9 * 60;
const BASE_LENGTH = 30;

const push = (event, params = {}) => ({ type: "push", event, params });
const view = (id, keys, extra = {}) => ({ id: `view-${id}`, label: `command_${id}`, keys, run: { type: "view", view: id }, ...extra });
const toggle = (id, on, labels, event, options, keywords) => ({
  id,
  keys: null,
  keywords,
  label: (s) => (on(s) ? labels[0] : labels[1]),
  run: (s) => push(event, options ? { option: on(s) ? options[0] : options[1] } : {}),
});

export const COMMANDS = [
  { id: "today", label: "command_today", keys: "T", run: { type: "key", key: "t" } },
  { id: "next", label: "command_next", keys: "J", run: { type: "key", key: "j" } },
  { id: "previous", label: "command_previous", keys: "K", run: { type: "key", key: "k" } },
  { id: "create", label: "command_new_event", keys: "C", run: { type: "create" } },
  view("day", "D"),
  view("three_day", "X"),
  view("week", "W", { notPhone: true }),
  view("month", "M"),
  view("agenda", "A"),
  { id: "bookable", label: "command_bookable", keys: "B", keywords: ["availability"], run: { type: "bookable" } },
  { id: "focus", keys: "F", wideOnly: true, label: (s) => (s.focus ? "command_leave_focus" : "command_focus"), run: { type: "key", key: "f" } },
  { id: "shortcuts", label: "command_shortcuts", keys: "?", keywords: ["help", "keys"], run: { type: "key", key: "?" } },
  { id: "show-all", label: "command_show_all", keys: null, run: push("calendar:show_all") },
  toggle("density", (s) => s.density === "compact", ["command_comfortable", "command_compact"], "calendar:set_density", ["comfortable", "compact"]),
  toggle("clock", (s) => s.time_format === "12h", ["command_clock_24", "command_clock_12"], "calendar:set_time_format", ["24h", "12h"]),
  toggle("week-start", (s) => s.week_start === "sunday", ["command_week_monday", "command_week_sunday"], "calendar:set_week_start", ["monday", "sunday"]),
  toggle("weekends", (s) => Boolean(s.show_weekends), ["command_hide_weekends", "command_show_weekends"], "calendar:toggle_weekends"),
  toggle("week-numbers", (s) => Boolean(s.show_week_numbers), ["command_hide_week_numbers", "command_show_week_numbers"], "calendar:toggle_week_numbers"),
  toggle("fold", (s) => Boolean(s.fold_night), ["command_unfold", "command_fold"], "calendar:toggle_fold_night"),
  // Off is the plain toggle; on asks the browser first (inside the key or
  // click that runs the row), and the surface saves it only once allowed.
  {
    ...toggle("reminders", (s) => Boolean(s.desktop_reminders), ["command_reminders_off", "command_reminders_on"], "calendar:toggle_desktop_reminders", undefined, ["reminders", "notifications"]),
    run: (s) => (s.desktop_reminders ? push("calendar:toggle_desktop_reminders") : { type: "permission", event: "calendar:enable_desktop_reminders" }),
  },
  { id: "import", label: "command_import", keys: null, run: push("calendar:ics_open") },
];

const fold = (text) =>
  String(text ?? "")
    .normalize("NFD")
    .replace(/\p{M}/gu, "")
    .toLowerCase()
    .replace(/[łøđß]/g, (c) => FOLDED[c]);

// 3 for a prefix, 2 for the start of a later word, 1 for anywhere, 0 for none.
export function matchScore(label, query) {
  const text = fold(label);
  const wanted = fold(query).trim();
  if (!wanted) return 0;
  let at = text.indexOf(wanted);
  if (at === -1) return 0;
  if (at === 0) return 3;
  while (at !== -1) {
    if (/[^\p{L}\p{N}]/u.test(text[at - 1])) return 2;
    at = text.indexOf(wanted, at + 1);
  }
  return 1;
}

// The label's score, or at most 1 for a keyword that matches.
const rowScore = (row, query) => Math.max(matchScore(row.label, query), ...(row.keywords || []).map((word) => Math.min(matchScore(word, query), 1)));

// A set's digit goes through the key table, which says what changed; the
// active set's own row is left out, as its digit does nothing.
function setRows(settings, strings) {
  const active = settings.active_set || 0;
  const rows = (settings.sets || [])
    .filter(({ position }) => position !== active)
    .map(({ position, name }) => ({ id: `set-${position}`, label: interpolate(strings.command_set, { name }), keys: String(position), keywords: ["set"], run: { type: "key", key: String(position) } }));
  if (active) rows.push({ id: "set-0", label: strings.command_leave_set, keys: "0", keywords: ["set"], run: { type: "key", key: "0" } });
  return rows;
}

function resolve(command, settings, strings) {
  const key = typeof command.label === "function" ? command.label(settings) : command.label;
  const run = typeof command.run === "function" ? command.run(settings) : command.run;
  return { id: command.id, label: strings[key] ?? "", keys: command.keys, keywords: command.keywords, run };
}

// The commands for `query`, as rows `{id, label, keys, run}`.
export function commandRows(query, { settings, strings, phone, wide = true }) {
  const commands = COMMANDS.filter((command) => !(phone && command.notPhone) && !(command.wideOnly && !wide)).map((command) => resolve(command, settings, strings));
  const sets = setRows(settings, strings);
  if (!String(query ?? "").trim()) {
    const byId = new Map(commands.map((row) => [row.id, row]));
    return [...EMPTY_HEAD.map((id) => byId.get(id)), ...sets, byId.get("shortcuts")].filter(Boolean);
  }
  return [...commands, ...sets]
    .map((row) => ({ row, score: rowScore(row, query) }))
    .filter(({ score }) => score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, MAX_COMMANDS)
    .map(({ row }) => row);
}

// `base` is where quick create would start (the hook's `nextDraft().base`),
// so the hint says what saving would do; without one, today at 09:00.
const parse = (text, { today, calendars = [], base }) =>
  parseQuick(text, base ?? { day: today, startMin: BASE_START, length: BASE_LENGTH, allDay: false, days: 1, calendar: null }, { today, calendars });

// "Tue 20 Oct", with the year when it is not this one.
function dayText(iso, today, strings) {
  const label = dateLabel(iso, strings);
  return iso.slice(0, 4) === today.slice(0, 4) ? label : `${label} ${iso.slice(0, 4)}`;
}

// "Go to …" when the whole query is a date.
export function dateRow(query, opts) {
  const text = String(query ?? "").trim();
  if (text.length < 2) return null;
  const parsed = parse(text, opts);
  if (!parsed.found.date || parsed.title !== "") return null;
  const date = parsed.start.slice(0, 10);
  return { id: "goto", label: interpolate(opts.strings.command_goto, { date: dayText(date, opts.today, opts.strings) }), date };
}

// "Add …" for a line with a title; first when the line says when.
export function addRow(query, opts) {
  const text = String(query ?? "").trim();
  if (text.length < 2) return null;
  const parsed = parse(text, opts);
  if (!parsed.title) return null;
  const said = parsed.found.time || parsed.found.date;
  return { id: "add", label: interpolate(opts.strings.command_add, { title: parsed.title }), hint: said ? whenText(parsed, opts) : null, text, first: Boolean(said) };
}

function whenText(parsed, { today, strings, timeFormat }) {
  const day = dayText(parsed.start.slice(0, 10), today, strings);
  if (parsed.allDay) return `${day}, ${strings.all_day}`;
  return `${day}, ${formatMinutes(parseWall(parsed.start) % MINUTES_PER_DAY, timeFormat)}`;
}
