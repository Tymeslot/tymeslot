/**
 * Tests for the canvas's event cache (calendar/cache.js). The server is the
 * only source of truth: each payload replaces everything it covers, so an
 * event deleted on the server disappears, and `reset` drops the lot.
 */
import { expect, test } from "vitest";
import { applyPayload, emptyCache, eventsForDays, isLoaded } from "../../calendar/cache.js";

const timed = (id, start, end) => ({ id, title: id, all_day: false, start, end });
const payload = (from, to, events, reset = false) => ({ range: { from, to }, events, reset });

test("a payload's days count as loaded, and only those", () => {
  const cache = applyPayload(emptyCache(), payload("2026-10-05", "2026-10-26", []));
  expect(isLoaded(cache, ["2026-10-05", "2026-10-25"])).toBe(true);
  expect(isLoaded(cache, ["2026-10-25", "2026-10-26"])).toBe(false);
});

test("a later payload replaces the events in its range and keeps the rest", () => {
  let cache = applyPayload(emptyCache(), payload("2026-10-05", "2026-10-26", [timed("event-1", "2026-10-06T09:00", "2026-10-06T10:00"), timed("event-2", "2026-10-20T09:00", "2026-10-20T10:00")]));
  cache = applyPayload(cache, payload("2026-10-12", "2026-11-02", [timed("event-3", "2026-10-28T09:00", "2026-10-28T10:00")]));

  expect([...cache.events.keys()].sort()).toEqual(["event-1", "event-3"]);
  expect(isLoaded(cache, ["2026-10-05", "2026-11-01"])).toBe(true);
});

test("reset drops everything first", () => {
  let cache = applyPayload(emptyCache(), payload("2026-10-05", "2026-10-26", [timed("event-1", "2026-10-06T09:00", "2026-10-06T10:00")]));
  cache = applyPayload(cache, payload("2026-11-02", "2026-11-23", [], true));

  expect(cache.events.size).toBe(0);
  expect(isLoaded(cache, ["2026-10-06"])).toBe(false);
});

test("eventsForDays returns what overlaps the days, including a multi-day event that started before them", () => {
  const cache = applyPayload(
    emptyCache(),
    payload("2026-10-05", "2026-10-26", [
      { id: "event-1", title: "Trip", all_day: true, start: "2026-10-10", end: "2026-10-14" },
      timed("event-2", "2026-10-20T09:00", "2026-10-20T10:00"),
    ]),
  );

  expect(eventsForDays(cache, ["2026-10-12", "2026-10-13"]).map((e) => e.id)).toEqual(["event-1"]);
});

test("an event that began before the reloaded range and is gone from the server disappears", () => {
  const trip = { id: "event-9", title: "Trip", all_day: true, start: "2026-10-10", end: "2026-10-14" };
  let cache = applyPayload(emptyCache(), payload("2026-10-05", "2026-10-12", [trip]));
  cache = applyPayload(cache, payload("2026-10-12", "2026-10-19", []));

  expect(cache.events.size).toBe(0);
});

test("back-to-back payloads merge into one loaded range", () => {
  let cache = applyPayload(emptyCache(), payload("2026-10-05", "2026-10-12", []));
  cache = applyPayload(cache, payload("2026-10-12", "2026-10-19", []));

  expect(cache.ranges.length).toBe(1);
});
