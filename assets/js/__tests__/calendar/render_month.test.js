/**
 * Tests for the month view's HTML (calendar/render_month.js), run against
 * jsdom: wide, with chips, bars and "+N"; and on a phone, with dots and the
 * chosen day's agenda below the grid.
 */
import { describe, expect, test } from "vitest";
import { renderMonth } from "../../calendar/render_month.js";
import { normaliseEvent, parseWall, periodDays } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  week_number: "Week %{number}",
  today: "Today",
  ended: "ended",
  shown_as_free: "shown as free",
  waiting_to_sync: "waiting to sync",
  request: "Request",
  request_expired: "Expired",
  request_aria: "request waiting for your answer",
  request_expired_aria: "request expired without an answer",
  open_day: "%{date}, open day view",
  empty_day: "Nothing planned on this day.",
  month_more: "More on %{date}: %{count}",
  month_attention: "includes something that needs your attention",
  month_select: "%{date}, show this day's events",
  day_events: "Events: %{count}",
  agenda_until: "Until %{time}",
  agenda_from: "From %{time}",
};
const ev = (id, title, start, end, extra = {}) => normaliseEvent({ id, kind: "event", title, all_day: false, start, end, colour: "calendar-2", free: false, attention: false, ...extra });
const days = periodDays("month", "2026-10-14", "monday", true);
const events = [
  ev("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00"),
  ev("event-2", "Planning", "2026-10-14T14:00", "2026-10-14T15:00"),
  ev("event-3", "Conference", "2026-10-13", "2026-10-16", { all_day: true, colour: "calendar-3" }),
];
const draw = (opts = {}) => {
  const holder = document.createElement("div");
  holder.innerHTML = renderMonth({ days, date: "2026-10-14", today: "2026-10-14", events, settings: { time_format: "24h" }, strings, phone: false, cellHeight: 100, now: parseWall("2026-10-14T08:30"), ...opts });
  return holder;
};

describe("wide", () => {
  test("six weeks of days, each a cell with its day-number button", () => {
    const holder = draw();
    expect(holder.querySelectorAll("[data-month-cell]")).toHaveLength(42);
    expect(holder.querySelectorAll("button[data-month-day]")).toHaveLength(42);
    expect(holder.querySelector(".cal-month").getAttribute("aria-label")).toBe("Oct 2026");
    expect(holder.querySelector('[data-month-day="2026-10-15"]').getAttribute("aria-label")).toBe("Thu 15 Oct, open day view");
  });

  test("today is marked, the date is the one tab stop, other months are set apart", () => {
    const holder = draw({ date: "2026-10-20" });
    expect(holder.querySelector('[data-month-day="2026-10-14"]').getAttribute("aria-current")).toBe("date");
    expect(holder.querySelector('[data-month-day="2026-10-20"]').getAttribute("tabindex")).toBe("0");
    expect(holder.querySelectorAll('button[data-month-day][tabindex="0"]')).toHaveLength(1);
    expect(holder.querySelector('[data-month-cell="2026-09-28"]').classList.contains("is-other-month")).toBe(true);
    expect(holder.querySelector('[data-month-cell="2026-10-01"]').classList.contains("is-other-month")).toBe(false);
  });

  test("a multi-day event is one bar across its days", () => {
    const bar = draw().querySelector('.cal-mbar[data-event-id="event-3"]');
    expect(bar.getAttribute("style")).toContain("grid-column:2 / 5");
    expect(bar.getAttribute("style")).toContain("grid-row:2");
    expect(bar.getAttribute("aria-label")).toBe("Conference, All day, Tue 13 Oct – Thu 15 Oct");
  });

  test("timed events are chips under the bars, with their start time", () => {
    const chip = draw().querySelector('.cal-mchip[data-event-id="event-1"]');
    expect(chip.getAttribute("style")).toContain("grid-column:3;grid-row:3");
    expect(chip.querySelector(".cal-mchip-time").textContent).toBe("11:00");
    expect(chip.querySelector(".cal-mchip-title").textContent).toBe("Design review");
    expect(chip.getAttribute("aria-label")).toBe("Design review, Wed 14 Oct, 11:00–12:00");
  });

  test("what does not fit goes behind +N, which names the day", () => {
    const holder = draw({ cellHeight: 48 });
    const more = holder.querySelector('button[data-month-more="2026-10-14"]');
    expect(more.textContent).toBe("+3");
    expect(more.getAttribute("aria-label")).toBe("More on Wed 14 Oct: 3");
    expect(holder.querySelector('.cal-mchip[data-event-id="event-1"]')).toBeNull();
  });

  test("compact density fits more of a day into the same cell before its +N", () => {
    const comfortable = draw({ cellHeight: 80 });
    const compact = draw({ cellHeight: 80, settings: { time_format: "24h", density: "compact" } });
    expect(comfortable.querySelector('[data-month-more="2026-10-14"]')).not.toBeNull();
    expect(compact.querySelector('[data-month-more="2026-10-14"]')).toBeNull();
    expect(compact.querySelectorAll('.cal-mchip[data-day="2026-10-14"]')).toHaveLength(2);
    expect(compact.querySelector(".cal-month").dataset.density).toBe("compact");
    expect(comfortable.querySelector(".cal-month").dataset.density).toBe("comfortable");
  });

  test("a +N hiding a request waiting for an answer carries the warning", () => {
    const request = ev("booking-9", "Anna", "2026-10-14T16:00", "2026-10-14T16:30", { kind: "booking", request: true });
    const quiet = ev("event-8", "Standup", "2026-10-14T09:00", "2026-10-14T09:15", { attention: true });
    const more = draw({ cellHeight: 48, events: [...events, request, quiet] }).querySelector('[data-month-more="2026-10-14"]');
    expect(more.classList.contains("is-warn")).toBe(true);
    expect(more.getAttribute("aria-label")).toContain("includes something that needs your attention");
  });

  test("a timed event of a day or more is labelled with its times, not all day", () => {
    const long = ev("event-10", "Retreat", "2026-10-14T09:00", "2026-10-15T10:00");
    const bar = draw({ events: [long] }).querySelector('.cal-mbar[data-event-id="event-10"]');
    expect(bar.getAttribute("aria-label")).toBe("Retreat, 09:00–10:00, Wed 14 Oct – Thu 15 Oct");
  });

  test("a day's chips and +N follow its cell in document order", () => {
    const holder = draw();
    const cell = holder.querySelector('[data-month-cell="2026-10-14"]');
    expect(cell.nextElementSibling.dataset.eventId).toBe("event-1");
    expect(holder.querySelector('[data-month-cell="2026-10-13"]').nextElementSibling.dataset.eventId).toBe("event-3");
    const crowded = draw({ cellHeight: 48 }).querySelector('[data-month-cell="2026-10-14"]');
    expect(crowded.nextElementSibling.dataset.monthMore).toBe("2026-10-14");
  });

  test("a bar crossing two weeks is cut at the edges", () => {
    const trip = ev("event-11", "Trip", "2026-10-15", "2026-10-21", { all_day: true });
    const bars = [...draw({ events: [trip] }).querySelectorAll('.cal-mbar[data-event-id="event-11"]')];
    expect(bars).toHaveLength(2);
    expect(bars[0].classList.contains("cut-end")).toBe(true);
    expect(bars[0].classList.contains("cut-start")).toBe(false);
    expect(bars[1].classList.contains("cut-start")).toBe(true);
    expect(bars[1].classList.contains("cut-end")).toBe(false);
  });

  test("weeks can start on Sunday", () => {
    const sunday = periodDays("month", "2026-10-14", "sunday", true);
    const holder = draw({ days: sunday });
    expect([...holder.querySelectorAll(".cal-month-weekday")].map((d) => d.textContent)[0]).toBe("Sun");
    expect(sunday[0]).toBe("2026-09-27");
    expect(holder.querySelector("[data-month-cell]").dataset.monthCell).toBe("2026-09-27");
  });

  test("titles are escaped", () => {
    const holder = draw({ events: [ev("event-7", "<img src=x>", "2026-10-15T09:00", "2026-10-15T10:00")] });
    expect(holder.querySelector("img")).toBeNull();
  });
});

describe("phone", () => {
  test("cells are buttons with up to three dots, no chips, the chosen day pressed", () => {
    const holder = draw({ phone: true });
    expect(holder.querySelector(".cal-mchip")).toBeNull();
    const wed = holder.querySelector('button[data-month-day="2026-10-14"]');
    expect(wed.getAttribute("aria-pressed")).toBe("true");
    expect(wed.querySelectorAll(".cal-dot.cal-month-dot")).toHaveLength(3);
    expect(wed.getAttribute("aria-label")).toBe("Wed 14 Oct, show this day's events, Events: 3");
    expect(holder.querySelector('button[data-month-day="2026-10-13"]').querySelectorAll(".cal-month-dot")).toHaveLength(1);
    expect(holder.querySelector('button[data-month-day="2026-10-20"]').querySelectorAll(".cal-month-dot")).toHaveLength(0);
    expect(holder.querySelector('button[data-month-day="2026-10-15"]').getAttribute("aria-pressed")).toBe("false");
  });

  test("a free event's dot is hollow, and so is its row in the chosen day", () => {
    const free = [ev("event-9", "Focus", "2026-10-20T09:00", "2026-10-20T10:00", { free: true })];
    const holder = draw({ phone: true, date: "2026-10-20", events: [...events, free[0]] });
    expect(holder.querySelectorAll('button[data-month-day="2026-10-20"] .cal-month-dot.is-free')).toHaveLength(1);
    expect(holder.querySelectorAll('button[data-month-day="2026-10-14"] .cal-month-dot.is-free')).toHaveLength(0);
    expect(holder.querySelector('.cal-month-agenda [data-event-id="event-9"]').closest(".is-free")).not.toBeNull();
  });

  test("the chosen day's events follow the grid", () => {
    const below = draw({ phone: true }).querySelector(".cal-month-agenda");
    expect([...below.querySelectorAll("button[data-event-id]")].map((b) => b.dataset.eventId)).toEqual(["event-3", "event-1", "event-2"]);
  });

  test("a chosen day with nothing on it says so", () => {
    const below = draw({ phone: true, date: "2026-10-20" }).querySelector(".cal-month-agenda");
    expect(below.textContent).toContain("Nothing planned on this day.");
  });
});

describe("week numbers", () => {
  const on = { time_format: "24h", show_week_numbers: true };
  const numbers = (holder) => [...holder.querySelectorAll(".cal-weeknum")].map((cell) => cell.textContent);

  test("off: no gutter and no numbers", () => {
    const holder = draw();
    expect(holder.querySelector(".cal-month").classList.contains("has-weeknums")).toBe(false);
    expect(holder.querySelector(".cal-weeknum")).toBeNull();
  });

  test("on: one number per week, each named for screen readers", () => {
    const holder = draw({ settings: on });
    expect(holder.querySelector(".cal-month").classList.contains("has-weeknums")).toBe(true);
    expect(numbers(holder)).toEqual(["40", "41", "42", "43", "44", "45"]);
    expect(holder.querySelector(".cal-mweek .cal-weeknum").getAttribute("aria-label")).toBe("Week 40");
  });

  test("on a phone too", () => {
    expect(numbers(draw({ settings: on, phone: true }))).toEqual(["40", "41", "42", "43", "44", "45"]);
  });

  test("Sunday-start rows are numbered by the Monday after their Sunday", () => {
    const sundayDays = periodDays("month", "2026-10-14", "sunday", true);
    expect(sundayDays[0]).toBe("2026-09-27");
    expect(numbers(draw({ days: sundayDays, settings: on }))[0]).toBe("40");
  });

  test("the numbers leave every day cell in its own column", () => {
    const holder = draw({ settings: on });
    expect(holder.querySelector('[data-month-cell="2026-09-28"]').getAttribute("style")).toContain("grid-column:1;");
    expect(holder.querySelectorAll("[data-month-cell]")).toHaveLength(42);
  });
});
