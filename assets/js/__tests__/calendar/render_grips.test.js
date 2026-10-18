/**
 * A block shorter than the grips' minimum height gets no grips
 * (calendar/render.js). The layout never draws a block under 20px, so the
 * layout is stubbed here to hand the renderer a short one.
 */
import { afterEach, expect, test, vi } from "vitest";

vi.mock("../../calendar/layout.js", async (importOriginal) => {
  const real = await importOriginal();
  return {
    ...real,
    layoutColumn: (segments, opts) => real.layoutColumn(segments, opts).map((item) => ({ ...item, height: 14 })),
  };
});

const { renderGrid } = await import("../../calendar/render.js");
const { addDays, normaliseEvent, parseWall } = await import("../../calendar/time.js");

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
};
const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: false, time_format: "24h", working_hours: {} };

afterEach(() => {
  document.body.innerHTML = "";
});

test("a block under 18px keeps data-editable but gets no grips", () => {
  const container = document.createElement("div");
  container.innerHTML = renderGrid({
    view: "week",
    days: Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k)),
    events: [normaliseEvent({ id: "event-1", kind: "event", title: "Quick sync", all_day: false, start: "2026-10-14T11:00", end: "2026-10-14T11:15", colour: "calendar-2", editable: true, movable: true })],
    settings,
    strings,
    now: parseWall("2026-10-14T08:30"),
    width: 1000,
    measureWidth: (text) => text.length * 7,
    nightOpen: false,
  });
  const ev = container.querySelector('.cal-ev[data-event-id="event-1"]');
  expect(ev).not.toBeNull();
  expect(ev.hasAttribute("data-editable")).toBe(true);
  expect(ev.querySelector("[data-grip]")).toBeNull();
});
