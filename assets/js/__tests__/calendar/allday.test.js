/**
 * Tests for the all-day lane (calendar/allday.js): multi-day events are one
 * bar in the same grid as the day columns, lanes stack, and past the lane
 * limit each day gets a "+N".
 */
import { expect, test } from "vitest";
import { layoutAllDay } from "../../calendar/allday.js";
import { addDays, normaliseEvent } from "../../calendar/time.js";

const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const allDay = (id, start, end) => normaliseEvent({ id, title: id, all_day: true, start, end });

test("a multi-day event is one bar across its days", () => {
  const { bars, rows } = layoutAllDay([allDay("trip", "2026-10-13", "2026-10-16")], week, { maxLanes: 3 });
  expect(bars).toEqual([{ id: "trip", startIndex: 1, endIndex: 3, lane: 0, cutStart: false, cutEnd: false }]);
  expect(rows).toBe(1);
});

test("an event running past the week is cut at the edge", () => {
  const { bars } = layoutAllDay([allDay("leave", "2026-10-16", "2026-10-21")], week, { maxLanes: 3 });
  expect(bars[0]).toMatchObject({ startIndex: 4, endIndex: 6, cutStart: false, cutEnd: true });
});

test("overlapping bars take separate lanes", () => {
  const { bars } = layoutAllDay([allDay("a", "2026-10-13", "2026-10-15"), allDay("b", "2026-10-14", "2026-10-16")], week, { maxLanes: 3 });
  expect(bars.map((bar) => bar.lane)).toEqual([0, 1]);
});

test("beyond the lane limit the rest become a per-day +N", () => {
  const four = ["a", "b", "c", "d"].map((id) => allDay(id, "2026-10-14", "2026-10-15"));
  const { bars, more, rows } = layoutAllDay(four, week, { maxLanes: 3 });
  expect(bars).toHaveLength(2);
  expect(more).toEqual([0, 0, 2, 0, 0, 0, 0]);
  expect(rows).toBe(3);
});

test("a timed event of a day or more joins the lane", () => {
  const long = normaliseEvent({ id: "conf", title: "Conference", all_day: false, start: "2026-10-14T20:00", end: "2026-10-15T22:00" });
  expect(layoutAllDay([long], week, { maxLanes: 3 }).bars[0]).toMatchObject({ startIndex: 2, endIndex: 3 });
});

test("an event only on hidden weekend days drops out", () => {
  const workdays = week.slice(0, 5);
  expect(layoutAllDay([allDay("sat", "2026-10-17", "2026-10-18")], workdays, { maxLanes: 3 }).bars).toEqual([]);
});

test("timed events stay out of the lane", () => {
  const meeting = normaliseEvent({ id: "m", title: "Meeting", all_day: false, start: "2026-10-14T09:00", end: "2026-10-14T10:00" });
  expect(layoutAllDay([meeting], week, { maxLanes: 3 })).toEqual({ bars: [], more: [0, 0, 0, 0, 0, 0, 0], rows: 0 });
});
