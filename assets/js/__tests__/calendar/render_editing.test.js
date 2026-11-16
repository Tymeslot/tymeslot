/**
 * Tests for how the canvas renderer (calendar/render.js) draws events the
 * organiser can change: hit areas for resizing, the roving tab stop left to
 * the hook, the move mode's mark, and a zoomed hour height.
 */
import { afterEach, expect, test } from "vitest";
import { renderGrid } from "../../calendar/render.js";
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
const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: false, time_format: "24h", working_hours: {} };
const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const review = (extra = {}) =>
  normaliseEvent({ id: "event-1", kind: "event", title: "Design review", all_day: false, start: "2026-10-14T11:00", end: "2026-10-14T12:00", colour: "calendar-2", editable: true, movable: true, ...extra });

function draw(overrides = {}) {
  const container = document.createElement("div");
  container.innerHTML = renderGrid({
    view: "week",
    days: week,
    events: [review()],
    settings,
    strings,
    now: parseWall("2026-10-14T08:30"),
    width: 1000,
    measureWidth: (text) => text.length * 7,
    nightOpen: false,
    ...overrides,
  });
  document.body.appendChild(container);
  return container;
}

const block = (container) => container.querySelector('.cal-ev[data-event-id="event-1"]');

afterEach(() => {
  document.body.innerHTML = "";
});

test("an event the organiser can change is draggable and has a hit area at each edge", () => {
  const ev = block(draw());
  expect(ev.hasAttribute("data-editable")).toBe(true);
  expect([...ev.querySelectorAll("[data-grip]")].map((grip) => grip.dataset.grip)).toEqual(["start", "end"]);
  expect(ev.getAttribute("aria-describedby")).toBe("calendar-keys-hint");
});

test("an event they cannot change has neither", () => {
  const ev = block(draw({ events: [review({ editable: false, movable: false })] }));
  expect(ev.hasAttribute("data-editable")).toBe(false);
  expect(ev.querySelector("[data-grip]")).toBeNull();
});

test("every block leaves the tab stop to the hook", () => {
  expect(block(draw()).getAttribute("tabindex")).toBe("-1");
});

test("the event in the move mode is marked", () => {
  expect(block(draw({ movingId: "event-1" })).classList.contains("is-moving")).toBe(true);
  expect(block(draw()).classList.contains("is-moving")).toBe(false);
});

test("a zoomed hour height overrides the density's", () => {
  const container = draw({ hourHeight: 80 });
  expect(container.querySelector(".cal-grid").getAttribute("style")).toContain("--cal-hour:80px");
  expect(block(container).style.top).toBe("880px");
});

test("the grips are hidden from assistive technology", () => {
  const grips = [...block(draw()).querySelectorAll("[data-grip]")];
  expect(grips).toHaveLength(2);
  for (const grip of grips) expect(grip.getAttribute("aria-hidden")).toBe("true");
});

test("the calendar copy of a booking has neither the drag mark nor grips", () => {
  const ev = block(draw({ events: [review({ editable: true, movable: false })] }));
  expect(ev.hasAttribute("data-editable")).toBe(false);
  expect(ev.querySelectorAll("[data-grip]")).toHaveLength(0);
});

test("an editable event that cannot be dragged is not marked editable", () => {
  const multiDay = draw({ events: [review({ start: "2026-10-14T23:00", end: "2026-10-15T01:00" })] });
  const blocks = multiDay.querySelectorAll('[data-event-id="event-1"]');
  expect(blocks.length).toBeGreaterThan(0);
  for (const el of blocks) expect(el.hasAttribute("data-editable")).toBe(false);

  const allDay = draw({ events: [review({ all_day: true, start: "2026-10-14", end: "2026-10-15" })] });
  const bars = allDay.querySelectorAll('[data-event-id="event-1"]');
  expect(bars.length).toBeGreaterThan(0);
  for (const el of bars) expect(el.hasAttribute("data-editable")).toBe(false);
});

test("a one-row draft shows its start, as an event does, and drops it in a column too narrow for both", () => {
  const draft = (title) => normaliseEvent({ id: "draft-1", kind: "draft", title, all_day: false, start: "2026-10-14T11:00", end: "2026-10-14T11:30", colour: "calendar-2" });
  const wide = draw({ events: [draft("Board prep")] }).querySelector('[data-draft-id="draft-1"]');
  expect(wide.querySelector(".cal-ev-title").textContent).toBe("Board prep");
  expect(wide.querySelector(".cal-ev-time").textContent).toBe("11:00");

  document.body.innerHTML = "";
  const narrow = draw({ events: [draft("Board prep")], width: 480 }).querySelector('[data-draft-id="draft-1"]');
  expect(narrow.querySelector(".cal-ev-title").textContent).toBe("Board prep");
  expect(narrow.querySelector(".cal-ev-time")).toBeNull();
});
