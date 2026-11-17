/**
 * Tests for "Open for booking" as pure functions of the draft
 * (calendar/opening.js): switching kind, the opening's chips, moving it,
 * the params it sends, how it is drawn, and the next slot that is not
 * already bookable. Today is Wednesday 14 October 2026.
 */
import { describe, expect, test } from "vitest";
import { applyChip, applyText, draftFromSlot } from "../../calendar/draft.js";
import { applyOpening, moveTo, nextOpenSlot, openingLook, toOpenPayload, withKind } from "../../calendar/opening.js";
import { addDays, dayNumber, formatWall, normaliseEvent, parseWall } from "../../calendar/time.js";

const types = [
  { id: 11, name: "Intro call", duration: 30 },
  { id: 12, name: "Deep dive", duration: 90 },
];
const thu = dayNumber("2026-10-15");
const slotDraft = (minute = 600) => draftFromSlot("d1", { day: thu, minute }, "7:work");
const span = (draft) => [formatWall(draft.start), formatWall(draft.end)];
const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const busy = (start, end) => normaliseEvent({ id: start, kind: "event", title: "x", all_day: false, start, end, free: false });

describe("switching kind", () => {
  test("a new draft is an event that happens once", () => {
    expect(slotDraft()).toMatchObject({ kind: "event", meetingType: null, repeat: "once", origin: null });
  });

  test("Open for booking picks the first meeting type and keeps the time", () => {
    const open = withKind(slotDraft(), "open", types);
    expect(open).toMatchObject({ kind: "open", meetingType: 11, repeat: "once", error: null });
    expect(span(open)).toEqual(["2026-10-15T10:00", "2026-10-15T10:30"]);
  });

  test("an opening shorter than its meeting type grows to hold one meeting", () => {
    const open = withKind({ ...slotDraft(), meetingType: 12 }, "open", types);
    expect(span(open)).toEqual(["2026-10-15T10:00", "2026-10-15T11:30"]);
  });

  test("an all-day draft becomes timed", () => {
    const allDay = applyChip(slotDraft(), "allDay", true);
    const open = withKind(allDay, "open", types);
    expect(open.allDay).toBe(false);
    expect(span(open)).toEqual(["2026-10-15T10:00", "2026-10-15T10:30"]);
  });

  test("without meeting types the draft stays an event", () => {
    expect(withKind(slotDraft(), "open", [])).toMatchObject({ kind: "event" });
  });

  test("back to Event keeps the time and drops a refusal", () => {
    const open = { ...withKind(slotDraft(), "open", types), error: { field: "start", message: "No" } };
    const event = withKind(open, "event", types);
    expect(event).toMatchObject({ kind: "event", error: null });
    expect(span(event)).toEqual(["2026-10-15T10:00", "2026-10-15T10:30"]);
  });
});

describe("the opening's chips", () => {
  const open = () => withKind(slotDraft(), "open", types);

  test("another meeting type, lengthened to its duration", () => {
    const changed = applyOpening(open(), "meetingType", "12", types);
    expect(changed.meetingType).toBe(12);
    expect(span(changed)).toEqual(["2026-10-15T10:00", "2026-10-15T11:30"]);
  });

  test("a meeting type that is not offered changes nothing", () => {
    expect(applyOpening(open(), "meetingType", "99", types)).toEqual(open());
  });

  test("how often it repeats", () => {
    expect(applyOpening(open(), "repeat", "weekly", types).repeat).toBe("weekly");
    expect(applyOpening(open(), "repeat", "daily", types).repeat).toBe("once");
  });

  test("moving keeps the length", () => {
    expect(span(moveTo(open(), parseWall("2026-10-16T13:15")))).toEqual(["2026-10-16T13:15", "2026-10-16T13:45"]);
  });
});

test("the params of calendar:open_booking", () => {
  const open = applyOpening(withKind(slotDraft(), "open", types), "repeat", "weekly", types);
  expect(toOpenPayload(open)).toEqual({ draft: "d1", meeting_type: 11, start: "2026-10-15T10:00", end: "2026-10-15T10:30", repeat: "weekly" });
});

test("an opening is drawn under its meeting type's name; an event is drawn as it was", () => {
  const strings = { open_draft_title: "Open for %{name}" };
  expect(openingLook(withKind(slotDraft(), "open", types), types, strings)).toEqual({ title: "Open for Intro call", colour: null, free: false, opening: true });
  expect(openingLook(slotDraft(), types, strings)).toEqual({});
});

describe("the next slot that is not already bookable", () => {
  const now = parseWall("2026-10-14T08:30");
  const windows = [
    { start: "2026-10-14T08:00", end: "2026-10-14T11:00" },
    { start: "2026-10-14T13:00", end: "2026-10-14T17:00" },
  ];
  const slot = (events, wins = windows, length = 30) => {
    const { startMin, endMin } = nextOpenSlot(now, week, events, wins, length);
    return [formatWall(startMin), formatWall(endMin)];
  };

  test("it skips bookable windows and busy events alike", () => {
    expect(slot([busy("2026-10-14T11:00", "2026-10-14T12:00")])).toEqual(["2026-10-14T12:00", "2026-10-14T12:30"]);
  });

  test("with nothing bookable it is C's own slot", () => {
    expect(slot([], [])).toEqual(["2026-10-14T08:45", "2026-10-14T09:15"]);
  });

  test("a slot already past is not offered: the draft stays where it is", () => {
    const lastWeek = Array.from({ length: 7 }, (_, k) => addDays("2026-10-05", k));
    expect(nextOpenSlot(now, lastWeek, [], [], 30)).toBeNull();
  });

  test("a gap shorter than the opening is skipped", () => {
    expect(slot([busy("2026-10-14T11:00", "2026-10-14T12:45")], windows, 30)).toEqual(["2026-10-14T17:00", "2026-10-14T17:30"]);
  });
});

describe("a time the organiser chose is never moved by C", () => {
  const fromC = () => ({ ...slotDraft(), origin: "next" });
  const options = { today: "2026-10-14", calendars: [] };

  test("changing the date, start, end or all day forgets where C put it", () => {
    for (const [chip, value] of [
      ["date", "2026-10-16"],
      ["start", "11:00"],
      ["end", "11:00"],
      ["allDay", true],
    ]) {
      expect(applyChip(fromC(), chip, value).origin).toBeNull();
    }
  });

  test("text that sets a time forgets it too; text that does not keeps it", () => {
    expect(applyText(fromC(), "Lunch at 13:00", options).origin).toBeNull();
    expect(applyText(fromC(), "Lunch", options).origin).toBe("next");
  });

  test("Busy/Free and the calendar keep it", () => {
    expect(applyChip(fromC(), "free", true).origin).toBe("next");
    expect(applyChip(fromC(), "calendar", "7:home").origin).toBe("next");
  });

  test("moving the draft forgets it", () => {
    expect(moveTo(fromC(), parseWall("2026-10-16T13:15")).origin).toBeNull();
  });
});
