/**
 * Tests for the month view's layout (calendar/month.js): weeks, bars for
 * long events, chips for timed ones, "+N" for what does not fit, dots and
 * the roving step. The fixture week runs Monday 12 to Sunday 18 October 2026.
 */
import { describe, expect, test } from "vitest";
import { chipCapacity, dayDots, monthLayout, monthStep, monthWeeks } from "../../calendar/month.js";
import { addDays, normaliseEvent, periodDays } from "../../calendar/time.js";

const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const WED = "2026-10-14";
let n = 0;
const base = (extra) => ({ id: `event-${(n += 1)}`, kind: "event", colour: "calendar-2", free: false, attention: false, ...extra });
const timed = (start, end, extra = {}) => normaliseEvent(base({ title: `T ${start}`, all_day: false, start, end, ...extra }));
const allDay = (start, end, extra = {}) => normaliseEvent(base({ title: `A ${start}`, all_day: true, start, end, ...extra }));
const ids = (events) => events.map((e) => e.id);
const at = (hour, extra = {}) => timed(`${WED}T${hour}:00`, `${WED}T${hour}:30`, extra);

test("monthWeeks cuts the month into six weeks of seven days", () => {
  const weeks = monthWeeks(periodDays("month", "2026-10-16", "monday", true));
  expect(weeks).toHaveLength(6);
  expect(weeks.every((w) => w.length === 7)).toBe(true);
  expect(weeks[0][0]).toBe("2026-09-28");
});

test("monthWeeks follows a Sunday week start", () => {
  expect(monthWeeks(periodDays("month", "2026-10-16", "sunday", true))[0][0]).toBe("2026-09-27");
});

describe("monthLayout", () => {
  test("long events run as bars across the week, timed ones are chips in start order", () => {
    const conference = allDay("2026-10-13", "2026-10-16");
    const late = timed(`${WED}T15:00`, `${WED}T16:00`);
    const early = timed(`${WED}T09:00`, `${WED}T10:00`);
    const [row] = monthLayout([week], [conference, late, early], { maxLanes: 4 });

    expect(row.bars).toEqual([expect.objectContaining({ id: conference.id, startIndex: 1, endIndex: 3, lane: 0 })]);
    expect(row.barRows).toBe(1);
    expect(ids(row.chips[WED])).toEqual([early.id, late.id]);
    expect(row.chips["2026-10-13"]).toEqual([]);
    expect(row.more[WED]).toBe(0);
  });

  test("a timed event over midnight is a chip on both days", () => {
    const overnight = timed(`${WED}T23:00`, "2026-10-15T01:00");
    const [row] = monthLayout([week], [overnight], { maxLanes: 3 });
    expect(ids(row.chips[WED])).toEqual([overnight.id]);
    expect(ids(row.chips["2026-10-15"])).toEqual([overnight.id]);
  });

  test("a day that fits shows every chip", () => {
    const three = ["09", "10", "11"].map((h) => at(h));
    const [row] = monthLayout([week], three, { maxLanes: 3 });
    expect(ids(row.chips[WED])).toEqual(ids(three));
    expect(row.more[WED]).toBe(0);
  });

  test("a crowded day keeps its last row for +N", () => {
    const four = ["09", "10", "11", "12"].map((h) => at(h));
    const [row] = monthLayout([week], four, { maxLanes: 3 });
    expect(ids(row.chips[WED])).toEqual([four[0].id, four[1].id]);
    expect(row.more[WED]).toBe(2);
    expect(row.warn[WED]).toBe(false);
  });

  test("events that need attention take the rows first, and a hidden one warns", () => {
    const plain = [at("09"), at("10")];
    const request = at("11", { kind: "booking", request: true });
    const [row] = monthLayout([week], [...plain, request], { maxLanes: 2 });
    expect(ids(row.chips[WED])).toEqual([request.id]);
    expect(row.more[WED]).toBe(2);
    expect(row.warn[WED]).toBe(false);

    const syncing = at("08", { attention: true });
    const [crowded] = monthLayout([week], [...plain, request, syncing], { maxLanes: 2 });
    expect(ids(crowded.chips[WED])).toEqual([syncing.id]);
    expect(crowded.more[WED]).toBe(3);
    expect(crowded.warn[WED]).toBe(true);
  });

  test("an expired request needs nothing and does not warn", () => {
    const expired = at("09", { kind: "booking", request: true, expired: true });
    const [row] = monthLayout([week], [at("08"), expired], { maxLanes: 1 });
    expect(ids(row.chips[WED])).toEqual([]);
    expect(row.more[WED]).toBe(2);
    expect(row.warn[WED]).toBe(false);
  });

  test("bars past the free lanes fold into +N on each day they cover", () => {
    const first = allDay("2026-10-12", "2026-10-14");
    const second = allDay("2026-10-13", "2026-10-15");
    const [row] = monthLayout([week], [first, second], { maxLanes: 2 });
    expect(row.barRows).toBe(1);
    expect(ids(row.bars)).toEqual([first.id]);
    expect([row.more["2026-10-12"], row.more["2026-10-13"], row.more[WED]]).toEqual([0, 1, 1]);
  });

  test("a hidden bar that needs attention warns on the days it covers", () => {
    const first = allDay("2026-10-12", "2026-10-14");
    const second = allDay("2026-10-13", "2026-10-15", { attention: true });
    const [row] = monthLayout([week], [first, second], { maxLanes: 2 });
    expect(row.warn["2026-10-13"]).toBe(true);
    expect(row.warn["2026-10-12"]).toBe(false);
  });

  test("drafts are left out", () => {
    const [row] = monthLayout([week], [at("09", { kind: "draft" })], { maxLanes: 3 });
    expect(row.chips[WED]).toEqual([]);
  });
});

test("chipCapacity counts the rows under the day number, never fewer than one", () => {
  expect(chipCapacity(100)).toBe(3);
  expect(chipCapacity(30)).toBe(1);
  expect(chipCapacity(0)).toBe(1);
  expect(chipCapacity(100, { head: 28, row: 24 })).toBe(3);
});

test("dayDots: up to three, what needs attention first, then all-day, then by start", () => {
  const events = [
    timed(`${WED}T15:00`, `${WED}T16:00`, { colour: "calendar-4" }),
    allDay(WED, "2026-10-15", { colour: "calendar-3" }),
    timed(`${WED}T09:00`, `${WED}T10:00`, { colour: "calendar-5" }),
    timed(`${WED}T18:00`, `${WED}T19:00`, { colour: "calendar-6", attention: true }),
  ];
  expect(dayDots(events, WED)).toEqual([
    { colour: "calendar-6", attention: true, free: false },
    { colour: "calendar-3", attention: false, free: false },
    { colour: "calendar-5", attention: false, free: false },
  ]);
  expect(dayDots(events, "2026-10-16")).toEqual([]);
});

test("dayDots marks a free event's dot, but not an expired request's", () => {
  const events = [at("09", { free: true }), at("11", { free: true, expired: true })];
  expect(dayDots(events, WED).map((d) => d.free)).toEqual([true, false]);
});

describe("monthStep", () => {
  test("arrows move by a day and by a week", () => {
    expect(monthStep(10, "ArrowRight")).toBe(11);
    expect(monthStep(10, "ArrowLeft")).toBe(9);
    expect(monthStep(10, "ArrowDown")).toBe(17);
    expect(monthStep(10, "ArrowUp")).toBe(3);
  });

  test("Home and End go to the ends of the week row", () => {
    expect(monthStep(10, "Home")).toBe(7);
    expect(monthStep(10, "End")).toBe(13);
  });

  test("a step off the grid, or another key, stays put", () => {
    expect(monthStep(0, "ArrowLeft")).toBe(0);
    expect(monthStep(3, "ArrowUp")).toBe(3);
    expect(monthStep(40, "ArrowDown")).toBe(40);
    expect(monthStep(10, "Enter")).toBe(10);
  });
});
