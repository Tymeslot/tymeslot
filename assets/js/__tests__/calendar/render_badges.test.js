/**
 * The badges an event block carries (calendar/render.js, render_month.js):
 * the seat lock on an event a group meeting with live seats sits on, which
 * is drawn without grips or `data-editable` and says why in its tooltip and
 * in the block's accessible name.
 */
import { describe, expect, test } from "vitest";
import { renderGrid } from "../../calendar/render.js";
import { renderMonth } from "../../calendar/render_month.js";
import { addDays, normaliseEvent, parseWall, periodDays } from "../../calendar/time.js";

const LOCK = "This is a group booking. Move it, cancel it or change who attends from the meeting instead.";
const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  open_day: "%{date}, open day view",
  seat_locked: LOCK,
  icons: { lock: '<svg class="cal-ev-badge-icon" aria-hidden="true"></svg>', guests: '<svg class="cal-ev-badge-icon" aria-hidden="true"></svg>' },
};
const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: false, time_format: "24h", working_hours: {} };
const ev = (extra = {}) => normaliseEvent({ id: "event-1", kind: "event", title: "Yoga class", all_day: false, start: "2026-10-14T11:00", end: "2026-10-14T12:00", colour: "calendar-2", editable: true, movable: true, ...extra });

const week = (events) => {
  const holder = document.createElement("div");
  holder.innerHTML = renderGrid({
    view: "week",
    days: Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k)),
    events,
    settings,
    strings,
    now: parseWall("2026-10-14T08:30"),
    width: 1000,
    measureWidth: (text) => text.length * 7,
    nightOpen: false,
  });
  return holder;
};

const month = (events) => {
  const holder = document.createElement("div");
  holder.innerHTML = renderMonth({ days: periodDays("month", "2026-10-14", "monday", true), date: "2026-10-14", today: "2026-10-14", events, settings, strings, cellHeight: 100, now: parseWall("2026-10-14T08:30") });
  return holder;
};

describe("seat lock", () => {
  test("a locked block has a lock with an accessible name and a tooltip, and no grips", () => {
    const block = week([ev({ locked: true, editable: false, movable: false })]).querySelector('.cal-ev[data-event-id="event-1"]');
    expect(block.classList.contains("is-locked")).toBe(true);
    expect(block.hasAttribute("data-editable")).toBe(false);
    expect(block.querySelector("[data-grip]")).toBeNull();

    const lock = block.querySelector(".cal-ev-lock");
    expect(lock.getAttribute("role")).toBe("img");
    expect(lock.getAttribute("aria-label")).toBe(LOCK);
    expect(lock.querySelector("svg")).not.toBeNull();
    const anchor = lock.closest("[data-tooltip]");
    expect(anchor.hasAttribute("data-tooltip-isolated")).toBe(true);
    expect(anchor.querySelector('[role="tooltip"]').textContent).toBe(LOCK);
    expect(block.getAttribute("aria-label")).toContain(LOCK);
  });

  test("an unlocked block has no lock and keeps its grips", () => {
    const block = week([ev()]).querySelector('.cal-ev[data-event-id="event-1"]');
    expect(block.querySelector(".cal-ev-lock")).toBeNull();
    expect(block.querySelector("[data-grip]")).not.toBeNull();
    expect(block.getAttribute("aria-label")).not.toContain(LOCK);
  });

  test("a locked month chip says so in its accessible name", () => {
    const chip = month([ev({ locked: true })]).querySelector('.cal-mchip[data-event-id="event-1"]');
    expect(chip.getAttribute("aria-label")).toContain(LOCK);
    const plain = month([ev()]).querySelector('.cal-mchip[data-event-id="event-1"]');
    expect(plain.getAttribute("aria-label")).not.toContain(LOCK);
  });
});

describe("guest replies", () => {
  const replies = (extra) => ({ accepted: 1, declined: 0, total: 3, label: "1 of 3 guests going", ...extra });

  test("a block shows accepted/total with its words in a tooltip and its accessible name", () => {
    const block = week([ev({ replies: replies() })]).querySelector('.cal-ev[data-event-id="event-1"]');
    const badge = block.querySelector(".cal-ev-replies");
    expect(badge.textContent).toBe("1/3");
    expect(badge.getAttribute("role")).toBe("img");
    expect(badge.getAttribute("aria-label")).toBe("1 of 3 guests going");
    expect(badge.closest("[data-tooltip]").querySelector('[role="tooltip"]').textContent).toBe("1 of 3 guests going");
    expect(block.getAttribute("aria-label")).toContain("1 of 3 guests going");
  });

  test("the badge is red once anyone declined, amber while answers are owed, green when all are going", () => {
    const tone = (r) => week([ev({ replies: replies(r) })]).querySelector(".cal-ev-replies").className;
    expect(tone({ declined: 1, label: "x" })).toContain("is-declined");
    expect(tone({})).toContain("is-pending");
    expect(tone({ accepted: 3 })).toContain("is-going");
  });

  test("an event nobody was asked about has no badge", () => {
    const block = week([ev()]).querySelector('.cal-ev[data-event-id="event-1"]');
    expect(block.querySelector(".cal-ev-replies")).toBeNull();
  });

  test("a month chip and an all-day bar carry a dot in the tone, and say it in their names", () => {
    const held = month([ev({ replies: replies({ declined: 1, label: "1 of 3 guests going, 1 declined" }) }), ev({ id: "event-2", all_day: true, start: "2026-10-13", end: "2026-10-15", replies: replies({ accepted: 3, label: "3 of 3 guests going" }) })]);
    const chip = held.querySelector('.cal-mchip[data-event-id="event-1"]');
    expect(chip.querySelector(".cal-mreplies.is-declined")).not.toBeNull();
    expect(chip.getAttribute("aria-label")).toContain("1 of 3 guests going, 1 declined");
    const bar = held.querySelector('.cal-mbar[data-event-id="event-2"]');
    expect(bar.querySelector(".cal-mreplies.is-going")).not.toBeNull();
    expect(bar.getAttribute("aria-label")).toContain("3 of 3 guests going");
    expect(month([ev()]).querySelector(".cal-mreplies")).toBeNull();
  });
});
