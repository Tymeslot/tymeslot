/**
 * Tests for the bookable-times layer's geometry (calendar/bookable.js):
 * windows cut per day column, clipped to the drawn hours, one label per
 * day, and whether any bookable time is in view.
 */
import { describe, expect, test } from "vitest";
import { bandsForColumns, bookableInView, clearLabelTop, labelPlacement, nextInView, windowsForDay } from "../../calendar/bookable.js";
import { parseWall } from "../../calendar/time.js";

const w = (start, end) => ({ start, end });
const week = ["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"];

describe("windowsForDay", () => {
  test("a window inside the day becomes minutes from its midnight", () => {
    expect(windowsForDay([w("2026-10-15T09:00", "2026-10-15T17:30")], "2026-10-15")).toEqual([{ startMin: 540, endMin: 1050 }]);
  });

  test("a window across midnight is split between the two days", () => {
    const windows = [w("2026-10-15T22:00", "2026-10-16T02:00")];
    expect(windowsForDay(windows, "2026-10-15")).toEqual([{ startMin: 1320, endMin: 1440 }]);
    expect(windowsForDay(windows, "2026-10-16")).toEqual([{ startMin: 0, endMin: 120 }]);
  });

  test("windows come back in time order, and empty or backwards ones are dropped", () => {
    const windows = [w("2026-10-15T14:00", "2026-10-15T16:00"), w("2026-10-15T09:00", "2026-10-15T09:00"), w("2026-10-15T12:00", "2026-10-15T11:00"), w("2026-10-15T09:00", "2026-10-15T10:00")];
    expect(windowsForDay(windows, "2026-10-15")).toEqual([
      { startMin: 540, endMin: 600 },
      { startMin: 840, endMin: 960 },
    ]);
  });

  test("other days get nothing", () => {
    expect(windowsForDay([w("2026-10-15T09:00", "2026-10-15T17:00")], "2026-10-16")).toEqual([]);
    expect(windowsForDay(undefined, "2026-10-16")).toEqual([]);
  });
});

describe("bandsForColumns", () => {
  test("one band per window on each visible day; days out of view get none", () => {
    const windows = [w("2026-10-15T09:00", "2026-10-15T12:00"), w("2026-10-15T14:00", "2026-10-15T17:00"), w("2026-10-20T09:00", "2026-10-20T17:00")];
    expect(bandsForColumns(windows, week, 0, 1440)).toEqual([
      { day: "2026-10-15", startMin: 540, endMin: 720 },
      { day: "2026-10-15", startMin: 840, endMin: 1020 },
    ]);
  });

  test("bands are clipped to the drawn hours; a band wholly in the folded night goes", () => {
    const windows = [w("2026-10-15T02:00", "2026-10-15T03:00"), w("2026-10-15T05:00", "2026-10-15T09:00")];
    expect(bandsForColumns(windows, week, 420, 1440)).toEqual([{ day: "2026-10-15", startMin: 420, endMin: 540 }]);
  });
});

describe("labelPlacement", () => {
  test("one label per day, at its earliest band", () => {
    const bands = [
      { day: "2026-10-15", startMin: 840, endMin: 1020 },
      { day: "2026-10-15", startMin: 540, endMin: 720 },
      { day: "2026-10-16", startMin: 600, endMin: 660 },
    ];
    expect(labelPlacement(bands)).toEqual([
      { day: "2026-10-15", startMin: 540 },
      { day: "2026-10-16", startMin: 600 },
    ]);
  });
});

describe("clearLabelTop", () => {
  const bands = [
    { top: 100, bottom: 200 },
    { top: 300, bottom: 400 },
  ];

  test("with no title line in the way it sits at the first band's top", () => {
    expect(clearLabelTop(bands, [], 20)).toEqual({ index: 0, top: 100 });
    expect(clearLabelTop(bands, [{ top: 150, bottom: 170 }], 20)).toEqual({ index: 0, top: 100 });
  });

  test("a title line at the band's top moves it to just below that line", () => {
    expect(clearLabelTop(bands, [{ top: 100, bottom: 120 }], 20)).toEqual({ index: 0, top: 120 });
    expect(clearLabelTop(bands, [{ top: 95, bottom: 115 }, { top: 115, bottom: 135 }], 20)).toEqual({ index: 0, top: 135 });
  });

  test("a band with no clear room passes it to the next band, and with none clear it keeps the first top", () => {
    expect(clearLabelTop(bands, [{ top: 100, bottom: 120 }, { top: 120, bottom: 140 }, { top: 140, bottom: 160 }, { top: 160, bottom: 180 }, { top: 180, bottom: 200 }], 20)).toEqual({ index: 1, top: 300 });
    expect(clearLabelTop([{ top: 100, bottom: 110 }], [{ top: 100, bottom: 120 }], 20)).toEqual({ index: 0, top: 100 });
    expect(clearLabelTop([], [], 20)).toBeNull();
  });
});

describe("nextInView", () => {
  test("true only when the next bookable time is on a visible day", () => {
    expect(nextInView({ at: "2026-10-15T09:00", label: "Thu 15 Oct, 09:00" }, week)).toBe(true);
    expect(nextInView({ at: "2026-10-26T09:00", label: "Mon 26 Oct, 09:00" }, week)).toBe(false);
    expect(nextInView(null, week)).toBe(false);
  });
});

describe("bookableInView", () => {
  const now = parseWall("2026-10-14T10:30");

  test("a window on a visible day that ends after now counts", () => {
    expect(bookableInView([w("2026-10-15T09:00", "2026-10-15T17:00")], week, now)).toBe(true);
    expect(bookableInView([w("2026-10-14T10:00", "2026-10-14T11:00")], week, now)).toBe(true);
  });

  test("a window already over, or off the visible days, does not", () => {
    expect(bookableInView([w("2026-10-14T09:00", "2026-10-14T10:00")], week, now)).toBe(false);
    expect(bookableInView([w("2026-10-26T09:00", "2026-10-26T17:00")], week, now)).toBe(false);
    expect(bookableInView([], week, now)).toBe(false);
  });
});
