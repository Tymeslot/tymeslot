/**
 * Tests for the command bar's own rows (calendar/commands.js): the command
 * registry and how a query matches it, the "Go to" row for a typed date and
 * the "Add" row for a typed event. Today is Wednesday 14 October 2026.
 */
import { describe, expect, test } from "vitest";
import { addRow, commandRows, dateRow, matchScore } from "../../calendar/commands.js";
import { commandSettings, commandStrings } from "./command_fixtures.js";

const opts = { today: "2026-10-14", calendars: [], strings: commandStrings, timeFormat: "24h" };
const rows = (query, extra = {}) => commandRows(query, { settings: commandSettings, strings: commandStrings, phone: false, ...extra });
const labels = (list) => list.map((row) => row.label);

describe("matchScore", () => {
  test("a prefix beats a word start, which beats anywhere", () => {
    expect(matchScore("Week", "we")).toBe(3);
    expect(matchScore("Show week numbers", "week")).toBe(2);
    expect(matchScore("Keyboard shortcuts", "cut")).toBe(1);
    expect(matchScore("Month", "week")).toBe(0);
  });

  test("case and accents are ignored", () => {
    expect(matchScore("Réunion", "reu")).toBe(3);
    expect(matchScore("Agenda", "AGE")).toBe(3);
  });
});

describe("commandRows", () => {
  test("before anything is typed: Today, New event, the views, the sets, then Keyboard shortcuts", () => {
    expect(labels(rows(""))).toEqual(["Today", "New event", "Day", "3 days", "Week", "Month", "Agenda", "Switch to Work", "Switch to Personal", "Keyboard shortcuts"]);
  });

  test("a set's row shows its digit and applies it", () => {
    const [work] = rows("work");
    expect(work).toMatchObject({ id: "set-1", label: "Switch to Work", keys: "1", run: { type: "key", key: "1" } });
  });

  test("leaving the set is offered on 0 only while a set is active", () => {
    expect(labels(rows("leave the"))).not.toContain("Leave the calendar set");
    const settings = { ...commandSettings, active_set: 2 };
    const [leave] = rows("leave the", { settings });
    expect(leave).toMatchObject({ id: "set-0", label: "Leave the calendar set", keys: "0", run: { type: "key", key: "0" } });
    expect(labels(rows("switch", { settings }))).toEqual(["Switch to Work"]);
  });

  test("display toggles name the choice they switch to", () => {
    expect(rows("density")[0]).toMatchObject({ label: "Use compact density", run: { type: "push", event: "calendar:set_density", params: { option: "compact" } } });
    const compact = { ...commandSettings, density: "compact", time_format: "12h", week_start: "sunday", show_weekends: false, fold_night: false, show_week_numbers: true, desktop_reminders: true };
    expect(rows("density", { settings: compact })[0].label).toBe("Use comfortable density");
    expect(rows("clock", { settings: compact })[0]).toMatchObject({ label: "Use the 24-hour clock", run: { params: { option: "24h" } } });
    expect(rows("start weeks", { settings: compact })[0]).toMatchObject({ label: "Start weeks on Monday", run: { params: { option: "monday" } } });
    expect(labels(rows("weekends", { settings: compact }))).toEqual(["Show weekends in week view"]);
    expect(labels(rows("early hours", { settings: compact }))).toEqual(["Fold early hours"]);
    expect(labels(rows("week numbers", { settings: compact }))).toEqual(["Hide week numbers"]);
    expect(rows("notifications", { settings: compact })[0]).toMatchObject({ label: "Turn off desktop notifications", run: { type: "push", event: "calendar:toggle_desktop_reminders" } });
    // Turning on waits for the browser's permission rather than pushing the toggle.
    expect(rows("notifications")[0]).toMatchObject({ label: "Turn on desktop notifications", run: { type: "permission", event: "calendar:enable_desktop_reminders" } });
  });

  test("focus mode goes to the dashboard, and is not offered on a phone", () => {
    expect(rows("focus")[0]).toMatchObject({ label: "Focus mode", keys: "F", run: { type: "key", key: "f" } });
    expect(rows("focus", { settings: { ...commandSettings, focus: true } })[0].label).toBe("Leave focus mode");
    expect(labels(rows("focus", { wide: false }))).toEqual([]);
  });

  test("prefix matches come first, and at most six commands follow a query", () => {
    expect(rows("w")[0].label).toBe("Week");
    expect(rows("e").length).toBe(6);
  });

  test("keywords and letters without a decomposition match", () => {
    expect(labels(rows("availability"))).toEqual(["Show or hide bookable times"]);
    expect(labels(rows("notifications"))).toEqual(["Turn on desktop notifications"]);
    expect(labels(rows("help"))).toEqual(["Keyboard shortcuts"]);
    expect(rows("set")[0].label).toBe("Switch to Work");
    expect(matchScore("Łódź", "lod")).toBe(3);
    expect(matchScore("Straße", "strasse")).toBe(3);
    expect(matchScore("Ørsted", "or")).toBe(3);
  });

  test("a phone has no Week view command", () => {
    expect(labels(rows("", { phone: true }))).not.toContain("Week");
    expect(labels(rows("", { phone: false }))).toContain("Week");
  });

  test("a set's name is not interpreted", () => {
    const settings = { ...commandSettings, sets: [{ position: 1, name: "<img src=x onerror=alert(1)>" }] };
    expect(rows("img", { settings })[0].label).toBe("Switch to <img src=x onerror=alert(1)>");
  });

  test("no command leads to the old calendar", () => {
    expect(rows("old calendar").filter((row) => row.run?.event === "calendar:switch_surface")).toEqual([]);
    expect(rows("back to the old")).toEqual([]);
  });
});

describe("dateRow", () => {
  test("a typed date goes there", () => {
    expect(dateRow("20 oct", opts)).toEqual({ id: "goto", label: "Go to Tue 20 Oct", date: "2026-10-20" });
    expect(dateRow("tomorrow", opts)).toMatchObject({ date: "2026-10-15", label: "Go to Thu 15 Oct" });
  });

  test("a date in another year names it", () => {
    expect(dateRow("20 oct 2027", opts)).toMatchObject({ date: "2027-10-20", label: "Go to Wed 20 Oct 2027" });
  });

  test("a line with a title, or with no date, is not a date", () => {
    expect(dateRow("lunch tomorrow", opts)).toBeNull();
    expect(dateRow("planning", opts)).toBeNull();
  });
});

describe("addRow", () => {
  test("a line with a time goes first and says when", () => {
    expect(addRow("tomorrow 10:00 Dentist", opts)).toEqual({ id: "add", label: "Add “Dentist”", hint: "Thu 15 Oct, 10:00", text: "tomorrow 10:00 Dentist", first: true });
  });

  test("a date and a title go first too", () => {
    expect(addRow("friday team lunch", opts)).toMatchObject({ first: true, label: "Add “Team lunch”" });
  });

  test("a bare title goes last, with no time to show", () => {
    expect(addRow("Dentist", opts)).toMatchObject({ first: false, hint: null, text: "Dentist" });
  });

  test("a line is read against the base quick create would start from", () => {
    const base = { day: "2026-10-14", startMin: 15 * 60, length: 45, allDay: false, days: 1, calendar: null };
    expect(addRow("tomorrow Dentist", { ...opts, base })).toMatchObject({ hint: "Thu 15 Oct, 15:00" });
  });

  test("one character, or no title, adds nothing", () => {
    expect(addRow("a", opts)).toBeNull();
    expect(addRow("tomorrow 10:00", opts)).toBeNull();
  });
});
