/**
 * Tests for the bookable-times layer in the canvas renderer
 * (calendar/render.js): bands behind events, one label per day, and the
 * note when nothing bookable is in view.
 */
import { afterEach, describe, expect, test } from "vitest";
import { renderGrid } from "../../calendar/render.js";
import { addDays, normaliseEvent, parseWall } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  open_day: "%{date}, open day view",
  empty_week: "Nothing planned this week.",
  calendar_role: "calendar",
  period_range: "%{from} to %{to}",
  show_early_hours: "Show the hours before %{time}",
  fold_early_hours: "Fold the hours before %{time}",
  early_hours: "Before %{time}: %{count}",
  bookable: "Bookable",
  bookable_label: "%{date}: bookable times for %{meeting_type}. Show what this means",
  next_bookable: "Next bookable time: %{when}",
  show: "Show",
  bookable_error: "Couldn't load your bookable times.",
};

const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: false, time_format: "24h", working_hours: {} };
const week = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const w = (start, end) => ({ start, end });
const layer = (overrides = {}) => ({ on: true, meeting_type: { id: 1, name: "Intro call" }, windows: [], next: null, error: false, timezone: "Europe/London", ...overrides });

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
    hourHeight: 52,
    ...overrides,
  });
  document.body.appendChild(container);
  return container;
}

const column = (grid, iso) => grid.querySelector(`.cal-col[data-day="${iso}"]`);

afterEach(() => {
  document.body.innerHTML = "";
});

describe("bands", () => {
  test("a window draws a band in its day's column, at its hours", () => {
    const grid = draw({ bookable: layer({ windows: [w("2026-10-15T09:00", "2026-10-15T17:00")] }) });
    const bands = column(grid, "2026-10-15").querySelectorAll(".cal-bookable");

    expect(bands).toHaveLength(1);
    expect(bands[0].style.top).toBe("468px");
    expect(bands[0].style.height).toBe("416px");
    expect(bands[0].getAttribute("aria-hidden")).toBe("true");
    expect(grid.querySelectorAll(".cal-bookable")).toHaveLength(1);
  });

  test("bands sit before the events in the column, so events draw over them", () => {
    const events = [normaliseEvent({ id: "event-1", kind: "event", title: "Review", all_day: false, start: "2026-10-15T10:00", end: "2026-10-15T11:00", colour: "calendar-2", free: false, attention: false })];
    const grid = draw({ events, bookable: layer({ windows: [w("2026-10-15T09:00", "2026-10-15T17:00")] }) });
    const band = column(grid, "2026-10-15").querySelector(".cal-bookable");
    const block = column(grid, "2026-10-15").querySelector('[data-event-id="event-1"]');

    expect(band.compareDocumentPosition(block) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  test("with the night folded a band starting before 07:00 starts at the strip's end", () => {
    const grid = draw({ settings: { ...settings, fold_night: true }, bookable: layer({ windows: [w("2026-10-15T05:00", "2026-10-15T09:00")] }) });
    const band = column(grid, "2026-10-15").querySelector(".cal-bookable");

    expect(band.style.top).toBe("28px");
    expect(band.style.height).toBe("104px");
  });

  test("a window across midnight draws in both columns", () => {
    const grid = draw({ bookable: layer({ windows: [w("2026-10-15T22:00", "2026-10-16T02:00")] }) });

    expect(column(grid, "2026-10-15").querySelector(".cal-bookable").style.top).toBe("1144px");
    expect(column(grid, "2026-10-16").querySelector(".cal-bookable").style.top).toBe("0px");
  });

  test("nothing is drawn with the layer off, with no meeting type or without a layer", () => {
    const windows = [w("2026-10-15T09:00", "2026-10-15T17:00")];
    for (const bookable of [layer({ on: false, windows }), layer({ meeting_type: null, windows }), null, undefined]) {
      const grid = draw({ bookable });
      expect(grid.querySelector(".cal-bookable, .cal-bookable-label, .cal-bookable-note")).toBeNull();
      document.body.innerHTML = "";
    }
  });
});

describe("labels", () => {
  test("one label per day, at its first band, naming the day and meeting type", () => {
    const windows = [w("2026-10-15T14:00", "2026-10-15T17:00"), w("2026-10-15T09:00", "2026-10-15T12:00"), w("2026-10-16T10:00", "2026-10-16T11:00")];
    const grid = draw({ bookable: layer({ windows }) });
    const labels = column(grid, "2026-10-15").querySelectorAll("[data-bookable-label]");

    expect(labels).toHaveLength(1);
    expect(labels[0].tagName).toBe("BUTTON");
    expect(labels[0].textContent).toBe("Bookable");
    expect(labels[0].style.top).toBe("468px");
    expect(labels[0].dataset.bookableLabel).toBe("2026-10-15");
    expect(labels[0].dataset.start).toBe("2026-10-15T09:00");
    expect(labels[0].dataset.end).toBe("2026-10-15T12:00");
    expect(labels[0].getAttribute("aria-label")).toBe("Thu 15 Oct: bookable times for Intro call. Show what this means");
    expect(grid.querySelectorAll("[data-bookable-label]")).toHaveLength(2);
  });

  test("a label's window is the day's part of a window across midnight", () => {
    const grid = draw({ bookable: layer({ windows: [w("2026-10-15T22:00", "2026-10-16T02:00")] }) });
    const label = column(grid, "2026-10-15").querySelector("[data-bookable-label]");

    expect(label.dataset.start).toBe("2026-10-15T22:00");
    expect(label.dataset.end).toBe("2026-10-16T00:00");
  });

  const freeEvent = (id, start, end) => normaliseEvent({ id, kind: "event", title: "Review", all_day: false, start, end, colour: "calendar-2", free: true, attention: false });

  test("an event starting with the band keeps its title line: the label sits just below it", () => {
    const events = [freeEvent("event-1", "2026-10-15T09:00", "2026-10-15T10:00")];
    const grid = draw({ events, bookable: layer({ windows: [w("2026-10-15T09:00", "2026-10-15T12:00")] }) });
    const label = column(grid, "2026-10-15").querySelector("[data-bookable-label]");

    expect(label.style.top).toBe("488px");
    expect(label.dataset.start).toBe("2026-10-15T09:00");
  });

  test("a band with no room clear of a title line passes the label to the day's next band", () => {
    const events = [freeEvent("event-1", "2026-10-15T09:00", "2026-10-15T09:30")];
    const windows = [w("2026-10-15T09:00", "2026-10-15T09:30"), w("2026-10-15T14:00", "2026-10-15T15:00")];
    const grid = draw({ events, bookable: layer({ windows }) });
    const label = column(grid, "2026-10-15").querySelector("[data-bookable-label]");

    expect(label.style.top).toBe(`${14 * 52}px`);
    expect(label.dataset.start).toBe("2026-10-15T14:00");
    expect(label.dataset.end).toBe("2026-10-15T15:00");
  });
});

describe("the note", () => {
  test("names the next bookable time when none is in view, with Show", () => {
    const grid = draw({ bookable: layer({ windows: [w("2026-10-26T09:00", "2026-10-26T17:00")], next: { at: "2026-10-26T09:00", label: "Mon 26 Oct, 09:00" } }) });
    const note = grid.querySelector(".cal-bookable-note");

    expect(note.getAttribute("role")).toBe("note");
    expect(note.textContent).toBe("Next bookable time: Mon 26 Oct, 09:00 · Show");
    expect(note.querySelector("button[data-bookable-show]").dataset.bookableShow).toBe("2026-10-26T09:00");
  });

  test("stays away while a bookable time is in view", () => {
    const grid = draw({ bookable: layer({ windows: [w("2026-10-15T09:00", "2026-10-15T17:00")], next: { at: "2026-10-15T09:00", label: "Thu 15 Oct, 09:00" } }) });
    expect(grid.querySelector(".cal-bookable-note")).toBeNull();
  });

  test("a time already over in view does not count as in view", () => {
    const grid = draw({ bookable: layer({ windows: [w("2026-10-14T09:00", "2026-10-14T10:00")], next: { at: "2026-10-26T09:00", label: "Mon 26 Oct, 09:00" } }) });
    expect(grid.querySelector(".cal-bookable-note").textContent).toContain("Mon 26 Oct, 09:00");
  });

  test("a failed load says so instead", () => {
    const grid = draw({ bookable: layer({ error: true }) });
    const note = grid.querySelector(".cal-bookable-note");

    expect(note.classList.contains("is-error")).toBe(true);
    expect(note.textContent).toBe("Couldn't load your bookable times.");
    expect(grid.querySelector(".cal-bookable")).toBeNull();
  });
});
