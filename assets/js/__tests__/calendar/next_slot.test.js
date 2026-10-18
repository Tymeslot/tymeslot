/**
 * Tests for where C puts a new draft (calendar/draft.js `nextSlot`).
 * Wednesday 14 October 2026 is today; the visible week runs Monday 12 to
 * Sunday 18 October.
 */
import { expect, test } from "vitest";
import { nextSlot } from "../../calendar/draft.js";
import { addDays, formatWall, normaliseEvent, parseWall } from "../../calendar/time.js";

const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const ev = (start, end, extra = {}) => normaliseEvent({ id: start, kind: "event", title: "x", all_day: false, start, end, free: false, ...extra });
const slot = (now, days = week, events = [], floor = 0) => {
  const { startMin, endMin } = nextSlot(parseWall(now), days, events, undefined, floor);
  return [formatWall(startMin), formatWall(endMin)];
};

test("today: the next quarter hour at least 15 minutes ahead, 30 minutes long", () => {
  expect(slot("2026-10-14T08:30")).toEqual(["2026-10-14T08:45", "2026-10-14T09:15"]);
  expect(slot("2026-10-14T08:31")).toEqual(["2026-10-14T09:00", "2026-10-14T09:30"]);
});

test("it skips past busy events, one after another", () => {
  const busy = [ev("2026-10-14T11:00", "2026-10-14T12:00"), ev("2026-10-14T12:00", "2026-10-14T12:20")];
  expect(slot("2026-10-14T10:40", week, busy)).toEqual(["2026-10-14T12:30", "2026-10-14T13:00"]);
});

test("free events, all-day events, drafts and other days do not count as busy", () => {
  const ignored = [
    ev("2026-10-14T11:00", "2026-10-14T12:00", { free: true }),
    ev("2026-10-14", "2026-10-15", { all_day: true }),
    ev("2026-10-14T10:00", "2026-10-14T12:00", { kind: "draft" }),
    ev("2026-10-15T11:00", "2026-10-15T12:00"),
  ];
  expect(slot("2026-10-14T10:40", week, ignored)).toEqual(["2026-10-14T11:00", "2026-10-14T11:30"]);
});

test("a gap shorter than the draft is skipped", () => {
  const busy = [ev("2026-10-14T09:00", "2026-10-14T09:50"), ev("2026-10-14T10:10", "2026-10-14T11:00")];
  expect(slot("2026-10-14T08:40", week, busy)).toEqual(["2026-10-14T11:00", "2026-10-14T11:30"]);
});

test("late in the evening it offers tomorrow at 09:00", () => {
  expect(slot("2026-10-14T22:00")).toEqual(["2026-10-15T09:00", "2026-10-15T09:30"]);
  expect(slot("2026-10-14T21:59")).toEqual(["2026-10-14T22:15", "2026-10-14T22:45"]);
});

test("with today out of view, 09:00 on the first visible day, past anything busy", () => {
  const next = Array.from({ length: 7 }, (_, k) => addDays("2026-10-19", k));
  expect(slot("2026-10-14T08:30", next)).toEqual(["2026-10-19T09:00", "2026-10-19T09:30"]);
  expect(slot("2026-10-14T08:30", next, [ev("2026-10-19T08:30", "2026-10-19T10:00")])).toEqual(["2026-10-19T10:00", "2026-10-19T10:30"]);
});

test("when nothing is free before midnight the first candidate stands", () => {
  const allEvening = [ev("2026-10-14T20:00", "2026-10-15T00:00")];
  expect(slot("2026-10-14T19:50", week, allEvening)).toEqual(["2026-10-14T20:15", "2026-10-14T20:45"]);
});

test("a folded night is a floor: nothing is drafted in its hidden rows", () => {
  expect(slot("2026-10-14T02:00", week, [], 360)).toEqual(["2026-10-14T06:00", "2026-10-14T06:30"]);
  expect(slot("2026-10-14T07:00", week, [], 360)).toEqual(["2026-10-14T07:15", "2026-10-14T07:45"]);
  const next = Array.from({ length: 7 }, (_, k) => addDays("2026-10-19", k));
  expect(slot("2026-10-14T08:30", next, [], 600)).toEqual(["2026-10-19T10:00", "2026-10-19T10:30"]);
});
