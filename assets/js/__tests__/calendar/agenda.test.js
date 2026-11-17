/**
 * Tests for the agenda's model (calendar/agenda.js): which loaded days it
 * can show, and its events grouped by day.
 */
import { describe, expect, test } from "vitest";
import { agendaDays, agendaGroups } from "../../calendar/agenda.js";
import { applyPayload, emptyCache } from "../../calendar/cache.js";
import { normaliseEvent } from "../../calendar/time.js";

const loaded = (from, to, cache = emptyCache()) => applyPayload(cache, { range: { from, to }, reset: false, events: [] });
const ev = (id, start, end, extra = {}) => normaliseEvent({ id, kind: "event", title: id, all_day: false, start, end, colour: "calendar-2", free: false, attention: false, ...extra });

describe("agendaDays", () => {
  test("the loaded days from the date, in a row", () => {
    const days = agendaDays(loaded("2026-10-14", "2026-11-11"), "2026-10-14");
    expect(days).toHaveLength(28);
    expect([days[0], days[27]]).toEqual(["2026-10-14", "2026-11-10"]);
  });

  test("never more than asked for", () => {
    expect(agendaDays(loaded("2026-10-14", "2026-11-11"), "2026-10-14", 5)).toHaveLength(5);
  });

  test("a chunk that joins on carries the run on", () => {
    const cache = loaded("2026-11-11", "2026-11-20", loaded("2026-10-14", "2026-11-11"));
    expect(agendaDays(cache, "2026-10-14").at(-1)).toBe("2026-11-19");
  });

  test("stops at a gap, and is empty when the date itself is not loaded", () => {
    const cache = loaded("2026-11-12", "2026-11-20", loaded("2026-10-14", "2026-11-11"));
    expect(agendaDays(cache, "2026-10-14").at(-1)).toBe("2026-11-10");
    expect(agendaDays(cache, "2026-12-01")).toEqual([]);
  });
});

describe("agendaGroups", () => {
  const days = ["2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"];
  const events = [
    ev("nine", "2026-10-14T09:00", "2026-10-14T10:00"),
    ev("eight", "2026-10-14T08:00", "2026-10-14T09:00"),
    ev("holiday", "2026-10-14", "2026-10-15", { all_day: true }),
    ev("trip", "2026-10-15T22:00", "2026-10-17T10:00"),
    ev("draft", "2026-10-18T09:00", "2026-10-18T10:00", { kind: "draft" }),
  ];
  const groups = agendaGroups(events, days, { today: "2026-10-14" });

  test("leaves empty days out, drafts too, and marks today", () => {
    expect(groups.map((g) => g.day)).toEqual(["2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"]);
    expect(groups.map((g) => g.today)).toEqual([true, false, false, false]);
  });

  test("lists all-day events first, then by start", () => {
    expect(groups[0].items.map((item) => item.event.id)).toEqual(["holiday", "eight", "nine"]);
    expect(groups[0].items[0]).toMatchObject({ allDay: true });
    expect(groups[0].items[1]).toMatchObject({ allDay: false, from: 480, to: 540, continuesBefore: false, continuesAfter: false });
  });

  test("a multi-day event appears on each day it covers, saying where it continues", () => {
    expect(groups[1].items[0]).toMatchObject({ allDay: false, from: 1320, to: 1440, continuesBefore: false, continuesAfter: true });
    expect(groups[2].items[0]).toMatchObject({ allDay: true, continuesBefore: true, continuesAfter: true });
    expect(groups[3].items[0]).toMatchObject({ allDay: false, from: 0, to: 600, continuesBefore: true, continuesAfter: false });
  });
});
