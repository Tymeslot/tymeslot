/**
 * Tests for the drag maths (calendar/drag.js): which slot a pointer is over,
 * and the snapped range a move or a resize shows.
 */
import { describe, expect, test } from "vitest";
import { beginDrag, draggable, dragRange, previewBox, slotAt, snap } from "../../calendar/drag.js";
import { MINUTES_PER_DAY, addDays, dayNumber, makeScale, normaliseEvent } from "../../calendar/time.js";

const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const scale = makeScale(52, false);
const geometry = { left: 56, top: 100, colWidth: 100, days: week, scale };
const wed = dayNumber("2026-10-14") * MINUTES_PER_DAY;
const thu = dayNumber("2026-10-15") * MINUTES_PER_DAY;

const event = (start, end, extra = {}) =>
  normaliseEvent({ id: "event-1", kind: "event", title: "Review", all_day: false, start, end, editable: true, movable: true, ...extra });
const review = event("2026-10-14T11:00", "2026-10-14T12:00");
const slot = (day, minute) => ({ index: 0, day: dayNumber(day), minute });

test("snap rounds to the nearest quarter hour", () => {
  expect([snap(7), snap(8), snap(52)]).toEqual([0, 15, 45]);
});

test("slotAt finds the day column and the minute under the pointer", () => {
  expect(slotAt({ x: 56 + 250, y: 100 + 52 * 11 }, geometry)).toEqual({ index: 2, day: dayNumber("2026-10-14"), minute: 660 });
  expect(slotAt({ x: 0, y: 0 }, geometry).index).toBe(0);
  expect(slotAt({ x: 5000, y: 0 }, geometry).index).toBe(6);
});

describe("move", () => {
  const grabbed = beginDrag("move", review, slot("2026-10-14", 680));

  test("keeps the grab offset, follows the pointer across days and snaps the start", () => {
    expect(dragRange(grabbed, slot("2026-10-15", 745))).toEqual({ startMin: thu + 720, endMin: thu + 780 });
  });

  test("stays inside the day", () => {
    expect(dragRange(grabbed, slot("2026-10-14", 1430))).toEqual({ startMin: wed + 1380, endMin: wed + 1440 });
    expect(dragRange(grabbed, slot("2026-10-14", 10))).toEqual({ startMin: wed, endMin: wed + 60 });
  });

  test("never starts inside the folded night", () => {
    expect(dragRange(grabbed, slot("2026-10-14", 100), 420)).toEqual({ startMin: wed + 420, endMin: wed + 480 });
  });
});

describe("resize", () => {
  test("the end edge snaps and keeps at least a quarter hour", () => {
    const end = beginDrag("end", review, slot("2026-10-14", 720));
    expect(dragRange(end, slot("2026-10-14", 755))).toEqual({ startMin: wed + 660, endMin: wed + 750 });
    expect(dragRange(end, slot("2026-10-14", 600))).toEqual({ startMin: wed + 660, endMin: wed + 675 });
  });

  test("the start edge snaps and keeps at least a quarter hour", () => {
    const start = beginDrag("start", review, slot("2026-10-14", 660));
    expect(dragRange(start, slot("2026-10-14", 610))).toEqual({ startMin: wed + 615, endMin: wed + 720 });
    expect(dragRange(start, slot("2026-10-14", 730))).toEqual({ startMin: wed + 705, endMin: wed + 720 });
  });

  test("ignores the day under the pointer", () => {
    const end = beginDrag("end", review, slot("2026-10-14", 720));
    expect(dragRange(end, slot("2026-10-16", 780))).toEqual({ startMin: wed + 660, endMin: wed + 780 });
  });
});

test("only single-day timed events the organiser can change are draggable", () => {
  expect(draggable(review)).toBe(true);
  expect(draggable(event("2026-10-14T11:00", "2026-10-14T12:00", { editable: false, movable: false }))).toBe(false);
  // The calendar copy of a booking: deletable, not movable.
  expect(draggable(event("2026-10-14T11:00", "2026-10-14T12:00", { editable: true, movable: false }))).toBe(false);
  expect(draggable(event("2026-10-14T23:00", "2026-10-15T01:00"))).toBe(false);
  expect(draggable(normaliseEvent({ id: "a", title: "Trip", all_day: true, start: "2026-10-14", end: "2026-10-15", editable: true, movable: true }))).toBe(false);
});

test("a zero-length event is not draggable, the server would refuse its range", () => {
  expect(draggable(event("2026-10-14T11:00", "2026-10-14T11:00"))).toBe(false);
  expect(draggable(event("2026-10-14T11:00", "2026-10-14T10:00"))).toBe(false);
});

test("previewBox is where a range is drawn in its column", () => {
  expect(previewBox({ startMin: wed + 660, endMin: wed + 720 }, scale)).toEqual({ top: 572, height: 52 });
  expect(previewBox({ startMin: wed + 660, endMin: wed + 663 }, scale).height).toBe(12);
});

describe("the day's edges", () => {
  test("a long event moved late with the night folded never ends past midnight", () => {
    const long = event("2026-10-14T06:00", "2026-10-14T23:59");
    const longer = { ...long, endMin: wed + 1440 };
    const grabbed = beginDrag("move", longer, slot("2026-10-14", 400));
    expect(dragRange(grabbed, slot("2026-10-14", 1000), 420)).toEqual({ startMin: wed + 360, endMin: wed + 1440 });
  });

  test("an end resize of an event starting at 23:50 never ends past midnight", () => {
    const late = { ...event("2026-10-14T23:50", "2026-10-14T23:59"), endMin: wed + 1440 };
    const end = beginDrag("end", late, slot("2026-10-14", 1440));
    expect(dragRange(end, slot("2026-10-14", 1440))).toEqual({ startMin: wed + 1430, endMin: wed + 1440 });
  });

  test("a start resize keeps a quarter hour before the end even with the night folded", () => {
    const early = event("2026-10-14T06:00", "2026-10-14T07:10");
    const start = beginDrag("start", early, slot("2026-10-14", 360));
    expect(dragRange(start, slot("2026-10-14", 430), 420)).toEqual({ startMin: wed + 415, endMin: wed + 430 });
  });
});
