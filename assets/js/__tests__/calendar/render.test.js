/**
 * Tests for the canvas renderer (calendar/render.js), run against jsdom.
 */
import { afterEach, describe, expect, test } from "vitest";
import { renderGrid, renderList, renderSkeleton } from "../../calendar/render.js";
import { addDays, normaliseEvent, parseWall } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  more: "more",
  allday_more: "%{count} more all-day events on %{date}",
  also_here: "Also here: %{titles}",
  shown_as_free: "shown as free",
  ended: "ended",
  waiting_to_sync: "waiting to sync",
  early_hours: "Before %{time}: %{count}",
  show_early_hours: "Show the hours before %{time}",
  fold_early_hours: "Fold the hours before %{time}",
  open_day: "%{date}, open day view",
  empty_day: "Nothing planned on this day.",
  empty_three_day: "Nothing planned on these days.",
  empty_week: "Nothing planned this week.",
  loading: "Loading calendar",
  list_label: "Events at this time",
};

const settings = {
  week_start: "monday",
  show_weekends: true,
  density: "comfortable",
  fold_night: true,
  time_format: "24h",
  working_hours: { 1: [540, 1020], 2: [540, 1020], 3: [540, 1020], 4: [540, 1020], 5: [540, 1020], 6: null, 7: null },
};

const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const timed = (id, title, start, end, extra = {}) =>
  normaliseEvent({ id, kind: "event", title, all_day: false, start, end, colour: "calendar-tomato", free: false, attention: false, ...extra });

function draw(overrides = {}) {
  const container = document.createElement("div");
  container.innerHTML = renderGrid({
    view: "week",
    days: week,
    events: [],
    settings,
    strings,
    now: parseWall("2026-10-14T10:30"),
    width: 1000,
    measureWidth: (text) => text.length * 7,
    nightOpen: false,
    ...overrides,
  });
  document.body.appendChild(container);
  return container;
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("renderGrid", () => {
  test("one column per day, each with a header that opens it", () => {
    const grid = draw();
    expect(grid.querySelectorAll(".cal-col")).toHaveLength(7);
    const header = grid.querySelector('[data-goto-day="2026-10-14"]');
    expect(header.getAttribute("aria-label")).toBe("Wed 14 Oct, open day view");
    expect(header.classList.contains("is-today")).toBe(true);
  });

  test("an event shows its title, its time and its calendar's colour", () => {
    const grid = draw({ events: [timed("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00")] });
    const block = grid.querySelector('[data-event-id="event-1"]');
    expect(block.textContent).toContain("Design review");
    expect(block.textContent).toContain("11:00–12:00");
    expect(block.getAttribute("style")).toContain("--cal-ev:var(--color-calendar-tomato)");
    expect(block.getAttribute("role")).toBe("button");
    expect(block.getAttribute("aria-label")).toBe("Design review, Wed 14 Oct, 11:00–12:00");
  });

  test("a past event is marked past and says so, without fading", () => {
    const grid = draw({ events: [timed("event-1", "Standup", "2026-10-14T09:00", "2026-10-14T09:30")] });
    const block = grid.querySelector('[data-event-id="event-1"]');
    expect(block.classList.contains("is-past")).toBe(true);
    expect(block.getAttribute("aria-label")).toContain("ended");
  });

  test("free, booking and attention events carry their own classes", () => {
    const grid = draw({
      events: [
        timed("event-1", "Focus", "2026-10-15T09:00", "2026-10-15T10:00", { free: true }),
        timed("booking-1", "Anna · Intro", "2026-10-15T11:00", "2026-10-15T12:00", { kind: "booking", colour: "booking" }),
        timed("event-2", "Dentist", "2026-10-15T13:00", "2026-10-15T14:00", { attention: true }),
      ],
    });
    expect(grid.querySelector('[data-event-id="event-1"]').classList.contains("is-free")).toBe(true);
    expect(grid.querySelector('[data-event-id="booking-1"]').classList.contains("is-booking")).toBe(true);
    expect(grid.querySelector('[data-event-id="booking-1"]').getAttribute("style")).toContain("--cal-ev:var(--cal-booking)");
    expect(grid.querySelector('[data-event-id="event-2"] .cal-ev-dot')).not.toBeNull();
  });

  test("a colour token that is not a plain token falls back to neutral", () => {
    const grid = draw({ events: [timed("event-1", "X", "2026-10-15T09:00", "2026-10-15T10:00", { colour: "red;background:url(x)" })] });
    expect(grid.querySelector('[data-event-id="event-1"]').getAttribute("style")).toContain("--cal-ev:var(--color-calendar-fallback)");
  });

  test("titles are escaped", () => {
    const grid = draw({ events: [timed("event-1", "<img src=x onerror=alert(1)>", "2026-10-15T09:00", "2026-10-15T10:00")] });
    expect(grid.querySelector("img")).toBeNull();
    expect(grid.querySelector('[data-event-id="event-1"]').textContent).toContain("<img src=x");
  });

  test("the folded night counts early events instead of drawing them", () => {
    const grid = draw({ events: [timed("event-1", "Gym", "2026-10-14T05:00", "2026-10-14T06:00")] });
    expect(grid.querySelector('[data-event-id="event-1"]')).toBeNull();
    expect(grid.querySelector('.cal-col[data-day="2026-10-14"] .cal-early').textContent).toBe("Before 07:00: 1");
    expect(grid.querySelector(".cal-night").getAttribute("aria-expanded")).toBe("false");
  });

  test("a folded column names its count to screen readers; an empty one is not a tab stop", () => {
    const grid = draw({ events: [timed("event-1", "Gym", "2026-10-14T05:00", "2026-10-14T06:00")] });
    const early = grid.querySelector('.cal-col[data-day="2026-10-14"] .cal-early');
    expect(early.tagName).toBe("BUTTON");
    expect(early.getAttribute("aria-label")).toBe("Before 07:00: 1, Show the hours before 07:00");
    const empty = grid.querySelector('.cal-col[data-day="2026-10-15"] .cal-early');
    expect(empty.tagName).toBe("SPAN");
    expect(empty.getAttribute("aria-hidden")).toBe("true");
    expect(grid.querySelectorAll("button.cal-early")).toHaveLength(1);
  });

  test("an event ending before 07:00 is counted even when its segment is padded past it", () => {
    const grid = draw({ events: [timed("event-1", "Blip", "2026-10-14T06:50", "2026-10-14T06:55")] });
    expect(grid.querySelector('[data-event-id="event-1"]')).toBeNull();
    expect(grid.querySelector('.cal-col[data-day="2026-10-14"] .cal-early').textContent).toBe("Before 07:00: 1");
  });

  test("all-day overflow chips say how many events and on which day", () => {
    const events = ["a", "b", "c", "d", "e"].map((id) => normaliseEvent({ id, kind: "event", title: id, all_day: true, start: "2026-10-14", end: "2026-10-15", colour: "calendar-tomato", free: false, attention: false }));
    const grid = draw({ events });
    const more = grid.querySelector("[data-allday-more]");
    expect(more.getAttribute("aria-label")).toMatch(/^\d+ more all-day events on Wed 14 Oct$/);
  });

  test("decorative hour labels and the now pill are hidden from screen readers; today is marked", () => {
    const grid = draw();
    expect([...grid.querySelectorAll(".cal-hour, .cal-now-pill")].every((el) => el.getAttribute("aria-hidden") === "true")).toBe(true);
    expect(grid.querySelector(".cal-night").hasAttribute("aria-hidden")).toBe(false);
    expect(grid.querySelector('[data-goto-day="2026-10-14"]').getAttribute("aria-current")).toBe("date");
    expect(grid.querySelector('[data-goto-day="2026-10-13"]').hasAttribute("aria-current")).toBe(false);
  });

  test("a title cannot break out of an attribute", () => {
    const grid = draw({ events: [timed("event-1", `'" onmouseover="x`, "2026-10-14T11:00", "2026-10-14T12:00")] });
    expect(grid.querySelector("[onmouseover]")).toBeNull();
    expect(grid.querySelector('[data-event-id="event-1"]').getAttribute("aria-label")).toContain(`'" onmouseover="x`);
  });

  test("the 12h clock shows in the axis and on events", () => {
    const grid = draw({ nightOpen: true, settings: { ...settings, time_format: "12h" }, events: [timed("event-1", "Lunch", "2026-10-14T13:00", "2026-10-14T14:30")] });
    const hours = [...grid.querySelectorAll(".cal-hour")].map((el) => el.textContent);
    expect(hours.some((t) => /1\s?PM/i.test(t))).toBe(true);
    expect(hours.some((t) => /^13/.test(t))).toBe(false);
    expect(grid.querySelector('[data-event-id="event-1"]').textContent).toMatch(/1:00\s?PM/i);
  });

  test("with no working hours at all nothing is shaded; a null day is still shaded whole", () => {
    expect(draw({ settings: { ...settings, working_hours: undefined } }).querySelectorAll(".cal-off")).toHaveLength(0);
    expect(draw({ settings: { ...settings, working_hours: { 1: null } } }).querySelectorAll('.cal-col[data-day="2026-10-12"] .cal-off')).toHaveLength(1);
  });

  test("opening the night draws early events", () => {
    const grid = draw({ nightOpen: true, events: [timed("event-1", "Gym", "2026-10-14T05:00", "2026-10-14T06:00")] });
    expect(grid.querySelector('[data-event-id="event-1"]')).not.toBeNull();
    expect(grid.querySelector(".cal-night").getAttribute("aria-expanded")).toBe("true");
  });

  test("hours outside the working day are shaded, and all of a day off", () => {
    const grid = draw();
    expect(grid.querySelectorAll('.cal-col[data-day="2026-10-12"] .cal-off')).toHaveLength(2);
    expect(grid.querySelectorAll('.cal-col[data-day="2026-10-17"] .cal-off')).toHaveLength(1);
  });

  test("the now line sits in today's column only, with the time in the axis", () => {
    const grid = draw();
    expect(grid.querySelectorAll(".cal-now")).toHaveLength(1);
    expect(grid.querySelector('.cal-col[data-day="2026-10-14"] .cal-now')).not.toBeNull();
    expect(grid.querySelector(".cal-now-pill").textContent).toBe("10:30");
  });

  test("an all-day event is a bar spanning its days in the lane", () => {
    const trip = normaliseEvent({ id: "event-9", kind: "event", title: "Trip", all_day: true, start: "2026-10-13", end: "2026-10-16", colour: "calendar-sage" });
    const bar = draw({ events: [trip] }).querySelector('.cal-adbar[data-event-id="event-9"]');
    expect(bar.getAttribute("style")).toContain("grid-column:3 / 6");
    expect(bar.textContent).toBe("Trip");
  });

  test("an empty week says so", () => {
    expect(draw().querySelector(".cal-empty").textContent).toBe("Nothing planned this week.");
  });

  test("a busy cluster folds into a chip listing what it hides", () => {
    const five = ["a", "b", "c", "d", "e"].map((id) => timed(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
    const chip = draw({ events: five }).querySelector(".cal-more");
    expect(chip.dataset.more.split(",")).toHaveLength(5);
    expect(chip.getAttribute("aria-label")).toContain("Also here: ");
  });

  test("compact density uses 38px hours", () => {
    expect(draw({ settings: { ...settings, density: "compact" } }).querySelector(".cal-grid").getAttribute("style")).toContain("--cal-hour:38px");
  });
});

test("renderSkeleton is a labelled status with one column per day", () => {
  const container = document.createElement("div");
  container.innerHTML = renderSkeleton(week.slice(0, 3), strings);
  expect(container.querySelector('[role="status"]').getAttribute("aria-label")).toBe("Loading calendar");
  expect(container.querySelectorAll(".cal-skeleton-col")).toHaveLength(3);
});

test("renderList lists events as buttons that open them", () => {
  const container = document.createElement("div");
  container.innerHTML = renderList([timed("event-1", "Standup", "2026-10-14T09:00", "2026-10-14T09:15")], { strings, timeFormat: "24h", label: "Events at this time" });
  const item = container.querySelector('button[data-event-id="event-1"]');
  expect(item.textContent).toContain("Standup");
  expect(item.textContent).toContain("09:00");
  expect(container.querySelector('[role="dialog"]').getAttribute("aria-label")).toBe("Events at this time");
});
