/**
 * Tests for the calendar canvas's wall-clock time maths (calendar/time.js).
 * `periodDays` and `shiftPeriod` mirror Tymeslot.CalendarGrid.Period, and
 * these cases match PeriodTest so the two cannot drift apart.
 */
import { describe, expect, test } from "vitest";
import {
  NIGHT_END,
  NIGHT_STRIP,
  addDays,
  dayNumber,
  formatHour,
  formatMinutes,
  isoFromDay,
  isoWeekday,
  makeScale,
  normaliseEvent,
  parseWall,
  periodDays,
  segmentsForDay,
  shiftPeriod,
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
});
