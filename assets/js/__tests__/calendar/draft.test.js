/**
 * Tests for the quick-create draft model (calendar/draft.js): a draft from
 * a click or a drag, what typing and the chips do to it, and the params it
 * sends. Today is Sunday 18 October 2026.
 */
import { describe, expect, test } from "vitest";
import { applyChip, applyText, createRange, draftEvent, draftFromRange, draftFromSlot, toPayload } from "../../calendar/draft.js";
import { MINUTES_PER_DAY, dayNumber, formatWall, parseWall } from "../../calendar/time.js";

const opts = { today: "2026-10-18", calendars: [{ key: "7:work", name: "Work" }, { key: "7:personal", name: "Personal", colour: "calendar-5" }] };
const tue = dayNumber("2026-10-20");
const at = (wall) => parseWall(wall);
const span = (draft) => [formatWall(draft.start), formatWall(draft.end)];
const slotDraft = (minute = 600) => draftFromSlot("d1", { day: tue, minute }, "7:work");

describe("a new draft", () => {
  test("a click takes the quarter hour under the pointer, 30 minutes long", () => {
    expect(span(slotDraft(608))).toEqual(["2026-10-20T10:00", "2026-10-20T10:30"]);
    expect(slotDraft(608)).toMatchObject({ id: "d1", calendar: "7:work", title: "", allDay: false, status: "editing", free: false });
  });

  test("a click late in the day is cut at midnight and never starts after 23:45", () => {
    expect(span(slotDraft(1439))).toEqual(["2026-10-20T23:45", "2026-10-21T00:00"]);
  });

  test("a click in a folded night starts at its end", () => {
    expect(span(draftFromSlot("d1", { day: tue, minute: 100 }, null, 420))).toEqual(["2026-10-20T07:00", "2026-10-20T07:30"]);
  });

  test("a drag covers the quarter hours it touched, either way up", () => {
    const down = createRange(tue, 540, 640);
    const up = createRange(tue, 640, 540);
    expect([formatWall(down.startMin), formatWall(down.endMin)]).toEqual(["2026-10-20T09:00", "2026-10-20T10:45"]);
    expect(up).toEqual(down);
  });

  test("a tiny drag is still 15 minutes, and stays inside the day", () => {
    const tiny = createRange(tue, 541, 542);
    expect(tiny.endMin - tiny.startMin).toBe(15);
    const late = createRange(tue, 1430, 1500);
    expect(formatWall(late.endMin)).toBe("2026-10-21T00:00");
  });

  test("the base is the slot, for reading the text against", () => {
    expect(slotDraft().base).toEqual({ day: "2026-10-20", startMin: 600, length: 30, allDay: false, days: 1, calendar: "7:work" });
  });
});

describe("typing", () => {
  test("a typed day and time move the draft; the title is what is left", () => {
    const draft = applyText(slotDraft(), "lunch tomorrow 13:00 /personal", opts);
    expect(span(draft)).toEqual(["2026-10-19T13:00", "2026-10-19T13:30"]);
    expect(draft).toMatchObject({ title: "Lunch", calendar: "7:personal", text: "lunch tomorrow 13:00 /personal" });
  });

  test("deleting the time again puts the draft back on its slot", () => {
    const typed = applyText(slotDraft(), "lunch 13:00", opts);
    expect(span(applyText(typed, "lunch", opts))).toEqual(["2026-10-20T10:00", "2026-10-20T10:30"]);
  });

  test("guests and a place come from the text", () => {
    const draft = applyText(slotDraft(), "1:1 @anna@example.com ;Room 4", opts);
    expect(draft).toMatchObject({ guests: ["anna@example.com"], location: "Room 4" });
  });
});

describe("chips", () => {
  test("moving the start keeps the length", () => {
    const draft = applyChip(applyText(slotDraft(), "call for 45m", opts), "start", "14:00");
    expect(span(draft)).toEqual(["2026-10-20T14:00", "2026-10-20T14:45"]);
  });

  test("a chip edit becomes the base, so typing on keeps it", () => {
    const moved = applyChip(slotDraft(), "start", "14:00");
    expect(span(applyText(moved, "call", opts))).toEqual(["2026-10-20T14:00", "2026-10-20T14:30"]);
  });

  test("changing the date keeps the time and the length", () => {
    const draft = applyChip(applyChip(slotDraft(), "end", "11:15"), "date", "2026-10-23");
    expect(span(draft)).toEqual(["2026-10-23T10:00", "2026-10-23T11:15"]);
  });

  test("an end before the start runs into the next day; an end at the start is 15 minutes", () => {
    const late = applyChip(slotDraft(), "start", "22:00");
    expect(span(applyChip(late, "end", "02:00"))).toEqual(["2026-10-20T22:00", "2026-10-21T02:00"]);
    expect(span(applyChip(late, "end", "22:00"))).toEqual(["2026-10-20T22:00", "2026-10-20T22:15"]);
  });

  test("all day on and off again restores the time it had", () => {
    const timed = applyChip(slotDraft(), "start", "14:00");
    const allDay = applyChip(timed, "allDay", true);
    expect([allDay.allDay, allDay.end - allDay.start]).toEqual([true, MINUTES_PER_DAY]);
    expect(span(applyChip(allDay, "allDay", false))).toEqual(["2026-10-20T14:00", "2026-10-20T14:30"]);
  });

  test("time chips do nothing on an all-day draft, and a cleared input changes nothing", () => {
    const allDay = applyChip(slotDraft(), "allDay", true);
    expect(applyChip(allDay, "start", "14:00")).toBe(allDay);
    expect(applyChip(slotDraft(), "start", "")).toEqual(slotDraft());
    expect(applyChip(slotDraft(), "date", "")).toEqual(slotDraft());
  });

  test("calendar and free", () => {
    expect(applyChip(slotDraft(), "calendar", "7:personal")).toMatchObject({ calendar: "7:personal", base: { calendar: "7:personal" } });
    expect(applyChip(slotDraft(), "free", true).free).toBe(true);
  });

  test("a chip edit clears a refusal shown for the old value", () => {
    const refused = { ...slotDraft(), error: { field: "start", message: "No" } };
    expect(applyChip(refused, "start", "11:00").error).toBeNull();
  });
});

describe("what is sent and drawn", () => {
  test("a timed draft sends wall times and every field", () => {
    const draft = applyText(slotDraft(), "Board meeting 14:00-15:30 ;Room 4 @cfo@example.com", opts);
    expect(toPayload(draft)).toEqual({
      draft: "d1",
      title: "Board meeting",
      start: "2026-10-20T14:00",
      end: "2026-10-20T15:30",
      all_day: false,
      calendar: "7:work",
      location: "Room 4",
      guests: ["cfo@example.com"],
      free: false,
    });
  });

  test("an all-day draft sends dates with an exclusive end, and an empty title stays empty", () => {
    const draft = applyChip(slotDraft(), "allDay", true);
    expect(toPayload(draft)).toMatchObject({ title: "", start: "2026-10-20", end: "2026-10-21", all_day: true });
  });

  test("the drawn draft is a kind draft event in its calendar's colour, pending while saving", () => {
    const draft = applyChip(slotDraft(), "calendar", "7:personal");
    expect(draftEvent(draft, opts.calendars)).toMatchObject({ id: "draft-d1", kind: "draft", colour: "calendar-5", pending: false, editable: false, movable: false });
    expect(draftEvent({ ...draft, status: "saving" }, opts.calendars).pending).toBe(true);
    expect(draftEvent({ ...draft, status: "created" }, opts.calendars).pending).toBe(true);
    expect(draftEvent({ ...draft, status: "panel" }, opts.calendars).pending).toBe(false);
  });

  test("a range from draftFromRange keeps its own length", () => {
    expect(span(draftFromRange("d2", { startMin: at("2026-10-20T09:00"), endMin: at("2026-10-20T10:45") }, null))).toEqual(["2026-10-20T09:00", "2026-10-20T10:45"]);
  });
});
