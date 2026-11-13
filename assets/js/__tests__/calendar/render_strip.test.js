/**
 * Tests for the phone's week strip (calendar/render_strip.js), run against jsdom.
 */
import { expect, test } from "vitest";
import { renderWeekStrip } from "../../calendar/render_strip.js";
import { addDays, normaliseEvent } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  open_day: "%{date}, open day view",
  strip_label: "Days of this week",
};
const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const ev = (id, start, end) => normaliseEvent({ id, kind: "event", title: id, all_day: false, start, end, colour: "calendar-2", free: false, attention: false });
const events = ["09", "10", "11", "12"].map((h) => ev(`event-${h}`, `2026-10-15T${h}:00`, `2026-10-15T${h}:30`));
const draw = () => {
  const holder = document.createElement("div");
  holder.innerHTML = renderWeekStrip({ days: week, date: "2026-10-16", today: "2026-10-14", events, strings });
  return holder;
};

test("seven day buttons that open their day, in a labelled strip", () => {
  const holder = draw();
  expect(holder.querySelector("nav.cal-strip").getAttribute("aria-label")).toBe("Days of this week");
  expect([...holder.querySelectorAll("button[data-goto-day]")].map((b) => b.dataset.gotoDay)).toEqual(week);
  expect(holder.querySelector('[data-goto-day="2026-10-16"]').getAttribute("aria-label")).toBe("Fri 16 Oct, open day view");
});

test("the shown day is pressed and today is marked", () => {
  const holder = draw();
  expect(holder.querySelector('[data-goto-day="2026-10-16"]').getAttribute("aria-pressed")).toBe("true");
  expect(holder.querySelectorAll('[aria-pressed="true"]')).toHaveLength(1);
  expect(holder.querySelector('[data-goto-day="2026-10-14"]').getAttribute("aria-current")).toBe("date");
});

test("a day shows at most three dots", () => {
  const holder = draw();
  expect(holder.querySelectorAll('[data-goto-day="2026-10-15"] .cal-dot')).toHaveLength(3);
  expect(holder.querySelectorAll('[data-goto-day="2026-10-12"] .cal-dot')).toHaveLength(0);
});
