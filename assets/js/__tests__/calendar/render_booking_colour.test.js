/**
 * A booking the organiser gave a colour of its own on the dashboard home
 * (calendar/render.js, render_month.js, render_agenda.js): its block, all-day
 * bar, month bar and chip dot are marked `has-colour` and carry the colour in
 * `--cal-ev`, and the stylesheets paint that colour instead of the booking
 * colour, darkened so the white text keeps its contrast. A booking without
 * one keeps the booking styling.
 */
import { describe, expect, test } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { renderGrid } from "../../calendar/render.js";
import { renderMonth } from "../../calendar/render_month.js";
import { addDays, normaliseEvent, parseWall, periodDays } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  open_day: "%{date}, open day view",
};
const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: false, time_format: "24h", working_hours: {} };
const booking = (extra = {}) => normaliseEvent({ id: "booking-1", kind: "booking", title: "Anna · Intro call", all_day: false, start: "2026-10-14T11:00", end: "2026-10-14T12:00", colour: "booking", editable: false, movable: false, ...extra });
const now = parseWall("2026-10-14T08:30");

const week = (events) => {
  const holder = document.createElement("div");
  holder.innerHTML = renderGrid({ view: "week", days: Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k)), events, settings, strings, now, width: 1000, measureWidth: (t) => t.length * 7, nightOpen: false });
  return holder;
};

const month = (events) => {
  const holder = document.createElement("div");
  holder.innerHTML = renderMonth({ days: periodDays("month", "2026-10-14", "monday", true), date: "2026-10-14", today: "2026-10-14", events, settings, strings, cellHeight: 100, now });
  return holder;
};

describe("a booking with a colour of its own", () => {
  test("its block and all-day bar are marked and carry the colour", () => {
    const held = week([booking({ colour: "calendar-grape" }), booking({ id: "booking-2", all_day: true, start: "2026-10-13", end: "2026-10-14", colour: "calendar-grape" })]);
    const block = held.querySelector('.cal-ev[data-event-id="booking-1"]');
    expect(block.classList.contains("is-booking")).toBe(true);
    expect(block.classList.contains("has-colour")).toBe(true);
    expect(block.getAttribute("style")).toContain("--cal-ev:var(--color-calendar-grape)");
    expect(held.querySelector('.cal-adbar[data-event-id="booking-2"]').classList.contains("has-colour")).toBe(true);
  });

  test("its month bar and chip are marked", () => {
    const held = month([booking({ colour: "calendar-grape" }), booking({ id: "booking-2", all_day: true, start: "2026-10-13", end: "2026-10-15", colour: "calendar-grape" })]);
    expect(held.querySelector('.cal-mchip[data-event-id="booking-1"]').classList.contains("has-colour")).toBe(true);
    expect(held.querySelector('.cal-mbar[data-event-id="booking-2"]').classList.contains("has-colour")).toBe(true);
  });

  test("a booking without one keeps the booking styling", () => {
    const block = week([booking()]).querySelector('.cal-ev[data-event-id="booking-1"]');
    expect(block.classList.contains("is-booking")).toBe(true);
    expect(block.classList.contains("has-colour")).toBe(false);
  });

  test("the stylesheets paint the colour, darkened, and the chip dot in it", () => {
    const dir = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css/components");
    const css = (readFileSync(resolve(dir, "calendar-surface.css"), "utf8") + readFileSync(resolve(dir, "calendar-views.css"), "utf8")).replace(/\/\*[\s\S]*?\*\//g, "");
    const rule = (selector) => {
      const found = css.split("}").find((chunk) => chunk.split("{")[0].split(",").some((s) => s.trim() === selector));
      return found ? found.split("{")[1] : "";
    };
    for (const selector of [".cal-ev.is-booking.has-colour", ".cal-adbar.is-booking.has-colour", ".cal-mbar.is-booking.has-colour"]) {
      expect(rule(selector)).toMatch(/background:\s*color-mix\(in srgb, var\(--cal-ev\) 55%, var\(--cal-ink\)\)/);
    }
    expect(rule(".cal-mchip.is-booking.has-colour .cal-mchip-dot")).toMatch(/background:\s*var\(--cal-ev\)/);
  });
});
