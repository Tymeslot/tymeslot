/**
 * Tests for the calendar canvas's wall-clock time maths (calendar/time.js).
 * `periodDays` and `shiftPeriod` mirror Tymeslot.CalendarGrid.Period, and
 * these cases match PeriodTest so the two cannot drift apart.
 */
import { describe, expect, test } from "vitest";
import {
  AGENDA_DAYS,
  AGENDA_MAX_DAYS,
  NIGHT_END,
  NIGHT_STRIP,
  addDays,
  dayNumber,
  formatHour,
  formatMinutes,
  isoFromDay,
  isTimeGrid,
  isoWeekday,
  makeScale,
  monthMatrix,
  needsAnswer,
  normaliseEvent,
  parseWall,
  periodDays,
  segmentsForDay,
  shiftPeriod,
  viewSwitchAnchor,
} from "../../calendar/time.js";

const range = (from, n) => Array.from({ length: n }, (_, k) => addDays(from, k));

describe("dates", () => {
  test("day numbers round-trip whatever the browser's own zone", () => {
    expect(isoFromDay(dayNumber("2026-10-16"))).toBe("2026-10-16");
    expect(dayNumber("2026-10-17") - dayNumber("2026-10-16")).toBe(1);
  });

  test("16 October 2026 is a Friday", () => {
    expect(isoWeekday(dayNumber("2026-10-16"))).toBe(5);
  });

  test("adding days crosses month ends", () => {
    expect(addDays("2026-10-31", 1)).toBe("2026-11-01");
  });

  test("wall-clock strings become minutes", () => {
    expect(parseWall("2026-10-16T09:30") - parseWall("2026-10-16T00:00")).toBe(570);
    expect(parseWall("2026-10-16")).toBe(dayNumber("2026-10-16") * 1440);
  });
});

describe("periodDays mirrors Period.days/4", () => {
  test("a Monday-start week around a Friday", () => {
    expect(periodDays("week", "2026-10-16", "monday", true)).toEqual(range("2026-10-12", 7));
  });

  test("a Sunday-start week", () => {
    expect(periodDays("week", "2026-10-16", "sunday", true)).toEqual(range("2026-10-11", 7));
  });

  test("Sunday belongs to the week before it when weeks start on Monday", () => {
    expect(periodDays("week", "2026-10-18", "monday", true)[0]).toBe("2026-10-12");
  });

  test("hidden weekends leave the working days", () => {
    expect(periodDays("week", "2026-10-16", "monday", false)).toEqual(range("2026-10-12", 5));
  });

  test("three days run forward from the anchor", () => {
    expect(periodDays("three_day", "2026-10-30", "monday", true)).toEqual(["2026-10-30", "2026-10-31", "2026-11-01"]);
  });

  test("a day is itself", () => {
    expect(periodDays("day", "2026-10-16", "monday", false)).toEqual(["2026-10-16"]);
  });
});

test("shiftPeriod steps by the view's length", () => {
  expect(shiftPeriod("week", "2026-10-16", 1)).toBe("2026-10-23");
  expect(shiftPeriod("three_day", "2026-10-16", -1)).toBe("2026-10-13");
  expect(shiftPeriod("day", "2026-10-31", 1)).toBe("2026-11-01");
});

describe("makeScale", () => {
  test("unfolded, minutes map straight to pixels", () => {
    const scale = makeScale(52, false);
    expect(scale.yOf(60)).toBe(52);
    expect(scale.firstMinute).toBe(0);
    expect(scale.height).toBe(52 * 24);
  });

  test("folded, the hours before 07:00 become one strip", () => {
    const scale = makeScale(52, true);
    expect(scale.yOf(0)).toBe(0);
    expect(scale.yOf(NIGHT_END)).toBe(NIGHT_STRIP);
    expect(scale.yOf(480)).toBe(NIGHT_STRIP + 52);
    expect(scale.firstMinute).toBe(NIGHT_END);
    expect(scale.height).toBe(NIGHT_STRIP + 17 * 52);
  });
});

describe("formatting matches the server's TimeFormat", () => {
  test("24-hour", () => {
    expect(formatMinutes(570, "24h")).toBe("09:30");
    expect(formatHour(8, "24h")).toBe("08:00");
  });

  test("12-hour", () => {
    expect(formatMinutes(870, "12h")).toBe("2:30 PM");
    expect(formatMinutes(0, "12h")).toBe("12:00 AM");
    expect(formatHour(12, "12h")).toBe("12 PM");
    expect(formatHour(7, "12h")).toBe("7 AM");
    expect(formatHour(24, "12h")).toBe("12 AM");
    expect(formatMinutes(570.4, "24h")).toBe("09:30");
  });
});

describe("normaliseEvent", () => {
  test("a timed event gets minute and day bounds", () => {
    const event = normaliseEvent({ id: "event-1", all_day: false, start: "2026-10-16T09:00", end: "2026-10-16T10:30" });
    expect(event.endMin - event.startMin).toBe(90);
    expect(event.startDay).toBe(dayNumber("2026-10-16"));
    expect(event.endDay).toBe(dayNumber("2026-10-17"));
    expect(event.long).toBe(false);
  });

  test("an all-day event keeps its exclusive end", () => {
    const event = normaliseEvent({ id: "event-2", all_day: true, start: "2026-10-16", end: "2026-10-18" });
    expect(event.endDay - event.startDay).toBe(2);
    expect(event.long).toBe(true);
  });

  test("a timed event of a day or more goes to the all-day lane", () => {
    const event = normaliseEvent({ id: "event-3", all_day: false, start: "2026-10-14T20:00", end: "2026-10-15T22:00" });
    expect(event.long).toBe(true);
    expect(event.endDay - event.startDay).toBe(2);
  });
});

describe("segmentsForDay", () => {
  const overnight = normaliseEvent({ id: "event-4", title: "Night shift", all_day: false, start: "2026-10-16T23:00", end: "2026-10-17T01:00" });

  test("splits an overnight event at midnight", () => {
    expect(segmentsForDay([overnight], "2026-10-16")).toEqual([{ id: "event-4", title: "Night shift", attention: false, s: 1380, e: 1440 }]);
    expect(segmentsForDay([overnight], "2026-10-17")).toEqual([{ id: "event-4", title: "Night shift", attention: false, s: 0, e: 60 }]);
  });

  test("gives a zero-length event fifteen minutes so it can be seen", () => {
    const blip = normaliseEvent({ id: "event-5", title: "Reminder", all_day: false, start: "2026-10-16T09:00", end: "2026-10-16T09:00" });
    expect(segmentsForDay([blip], "2026-10-16")[0]).toMatchObject({ s: 540, e: 555 });
  });

  test("leaves long events to the all-day lane", () => {
    const trip = normaliseEvent({ id: "event-6", title: "Trip", all_day: true, start: "2026-10-16", end: "2026-10-18" });
    expect(segmentsForDay([trip], "2026-10-16")).toEqual([]);
  });
  test("a request waiting for an answer needs attention; an expired one and a booking do not", () => {
    const at = (id, extra) => normaliseEvent({ id, title: id, all_day: false, start: "2026-10-16T09:00", end: "2026-10-16T10:00", kind: "booking", ...extra });
    const segments = segmentsForDay([at("open", { request: true }), at("lapsed", { request: true, expired: true }), at("swept", { expired: true }), at("plain", {})], "2026-10-16");
    expect(Object.fromEntries(segments.map((g) => [g.id, g.attention]))).toEqual({ open: true, lapsed: false, swept: false, plain: false });
    expect(needsAnswer({ request: true })).toBe(true);
    expect(needsAnswer({ request: true, expired: true })).toBe(false);
  });
});

describe("month and agenda mirror Period", () => {
  test("a month is six weeks of seven days from the week start before the first", () => {
    const days = periodDays("month", "2026-10-16", "monday", true);
    expect(days).toHaveLength(42);
    expect([days[0], days[41]]).toEqual(["2026-09-28", "2026-11-08"]);
  });

  test("a month starts on Sunday when weeks do", () => {
    const days = periodDays("month", "2026-10-16", "sunday", true);
    expect([days[0], days[41]]).toEqual(["2026-09-27", "2026-11-07"]);
  });

  test("a month keeps its weekends when the week hides them", () => {
    const days = periodDays("month", "2026-10-16", "monday", false);
    expect(days).toHaveLength(42);
    expect(days).toContain("2026-10-17");
  });

  test("monthMatrix is the month's days", () => {
    expect(monthMatrix("2026-10-16", "monday")).toEqual(periodDays("month", "2026-10-16", "monday", true));
  });

  test("a month steps by a calendar month, keeping the day where the month has it", () => {
    expect(shiftPeriod("month", "2026-10-16", 1)).toBe("2026-11-16");
    expect(shiftPeriod("month", "2026-01-15", -1)).toBe("2025-12-15");
    expect(shiftPeriod("month", "2026-12-15", 1)).toBe("2027-01-15");
  });

  test("31 January steps to the last day of February, leap years included", () => {
    expect(shiftPeriod("month", "2026-01-31", 1)).toBe("2026-02-28");
    expect(shiftPeriod("month", "2024-01-31", 1)).toBe("2024-02-29");
    expect(shiftPeriod("month", "2026-03-31", -1)).toBe("2026-02-28");
  });

  test("an agenda shows four weeks from its date and steps by four weeks", () => {
    const days = periodDays("agenda", "2026-10-14", "monday", false);
    expect(days).toHaveLength(AGENDA_DAYS);
    expect([days[0], days[27]]).toEqual(["2026-10-14", "2026-11-10"]);
    expect(shiftPeriod("agenda", "2026-10-14", 1)).toBe("2026-11-11");
    expect(shiftPeriod("agenda", "2026-10-14", -1)).toBe("2026-09-16");
  });

  test("an agenda extends at most 24 weeks", () => {
    expect(AGENDA_MAX_DAYS).toBe(6 * AGENDA_DAYS);
  });

  test("only day, three days and week are time grids", () => {
    expect(["day", "three_day", "week", "month", "agenda"].filter(isTimeGrid)).toEqual(["day", "three_day", "week"]);
  });
});

describe("viewSwitchAnchor mirrors Period.view_switch_anchor/4", () => {
  test("a week hands over today when today is in it", () => {
    expect(viewSwitchAnchor("week", "2026-10-16", "2026-10-14", "monday")).toBe("2026-10-14");
  });

  test("a week without today hands over its first day, mid-week anchor or not", () => {
    expect(viewSwitchAnchor("week", "2026-10-21", "2026-10-14", "monday")).toBe("2026-10-19");
    expect(viewSwitchAnchor("week", "2026-10-21", "2026-10-14", "sunday")).toBe("2026-10-18");
  });

  test("a week's first day follows the week start", () => {
    expect(viewSwitchAnchor("week", "2026-10-18", "2026-10-01", "sunday")).toBe("2026-10-18");
    expect(viewSwitchAnchor("week", "2026-10-18", "2026-10-01", "monday")).toBe("2026-10-12");
  });

  test("a month hands over today when today is one of its own days", () => {
    expect(viewSwitchAnchor("month", "2026-10-20", "2026-10-14", "monday")).toBe("2026-10-14");
  });

  test("a month without today hands over its first, even when its grid shows today", () => {
    expect(viewSwitchAnchor("month", "2026-11-14", "2026-10-28", "monday")).toBe("2026-11-01");
  });

  test("the views that start at their date keep it", () => {
    for (const view of ["day", "three_day", "agenda"]) {
      expect(viewSwitchAnchor(view, "2026-10-21", "2026-10-14", "monday")).toBe("2026-10-21");
    }
  });
});
