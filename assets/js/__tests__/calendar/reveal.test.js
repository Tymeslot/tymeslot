/**
 * Tests for finding an event to reveal in what the canvas drew
 * (calendar/reveal.js): its own block, the "+N" chip that hides it in a
 * time-grid cluster, the all-day lane or a month day; whether the night
 * must unfold first; and reading a search row's data.
 */
import { describe, expect, test } from "vitest";
import { applyPayload, emptyCache } from "../../calendar/cache.js";
import { needsNight, revealRequest, revealTarget } from "../../calendar/reveal.js";

const cache = applyPayload(emptyCache(), {
  range: { from: "2026-10-12", to: "2026-10-19" },
  reset: true,
  events: [
    { id: "event-1", all_day: false, start: "2026-10-14T13:00", end: "2026-10-14T14:00" },
    { id: "event-2", all_day: true, start: "2026-10-15", end: "2026-10-17" },
  ],
});

const root = (html) => {
  const div = document.createElement("div");
  div.innerHTML = html;
  return div;
};

describe("revealTarget", () => {
  test("an event drawn as itself is found as itself", () => {
    const el = root(`<div class="cal-col"><button class="cal-ev" data-event-id="event-1"></button></div>`);
    expect(revealTarget(el, ["event-1"], cache)).toEqual({ kind: "event", node: el.querySelector(".cal-ev"), id: "event-1" });
  });

  test("an item of an open list does not count; the chip that hides the event does", () => {
    const el = root(`<button class="cal-more" data-more="event-7,event-1" data-hidden="event-7,event-1">+2</button><div class="cal-list"><button data-event-id="event-1"></button></div>`);
    expect(revealTarget(el, ["event-1"], cache)).toMatchObject({ kind: "chip", node: el.querySelector(".cal-more") });
  });

  test("a chip that only shows the event among its cluster, not hiding it, does not count", () => {
    const el = root(`<button class="cal-more" data-more="event-1,event-7" data-hidden="event-7">+1</button>`);
    expect(revealTarget(el, ["event-1"], cache)).toBeNull();
  });

  test("an all-day event behind the lane's +N is found on a day it covers", () => {
    const el = root(`<button data-allday-more="2026-10-14">+1</button><button data-allday-more="2026-10-16">+1</button>`);
    expect(revealTarget(el, ["event-2"], cache)).toMatchObject({ kind: "allday", node: el.querySelector('[data-allday-more="2026-10-16"]') });
  });

  test("an event behind a month day's +N is found on its day", () => {
    const el = root(`<button data-month-more="2026-10-13">+3</button><button data-month-more="2026-10-14">+3</button>`);
    expect(revealTarget(el, ["event-1"], cache)).toMatchObject({ kind: "month", node: el.querySelector('[data-month-more="2026-10-14"]') });
  });

  test("ids are tried in order, and nothing found is null", () => {
    const el = root(`<button class="cal-ev" data-event-id="event-1"></button>`);
    expect(revealTarget(el, ["event-9", "event-1"], cache)).toMatchObject({ id: "event-1" });
    expect(revealTarget(el, ["event-9"], cache)).toBeNull();
  });
});

describe("needsNight", () => {
  test("only a timed event before 07:00 with the night folded and shut", () => {
    expect(needsNight(360, false, { fold_night: true }, false)).toBe(true);
    expect(needsNight(360, false, { fold_night: true }, true)).toBe(false);
    expect(needsNight(360, false, { fold_night: false }, false)).toBe(false);
    expect(needsNight(420, false, { fold_night: true }, false)).toBe(false);
    expect(needsNight(360, true, { fold_night: true }, false)).toBe(false);
    expect(needsNight(null, false, { fold_night: true }, false)).toBe(false);
  });
});

describe("revealRequest", () => {
  test("reads a search row's data", () => {
    expect(revealRequest({ revealIds: "event-1,booking-2", date: "2026-10-21", startMin: "660", allDay: "false" })).toEqual({ ids: ["event-1", "booking-2"], date: "2026-10-21", startMin: 660, allDay: false });
    expect(revealRequest({ revealIds: "event-3", date: "2026-10-22", allDay: "true" })).toEqual({ ids: ["event-3"], date: "2026-10-22", startMin: null, allDay: true });
  });
});
