/**
 * Tests for the canvas renderer (calendar/render.js), run against jsdom.
 */
import { afterEach, describe, expect, test } from "vitest";
import { dateLabel, renderGrid, renderList, renderSkeleton } from "../../calendar/render.js";
import { metricsFor } from "../../calendar/viewport.js";
import { addDays, normaliseEvent, parseWall } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  week_number: "Week %{number}",
  more: "more",
  allday_more: "%{count} more all-day events on %{date}",
  also_here: "Also here: %{titles}",
  shown_as_free: "shown as free",
  ended: "ended",
  waiting_to_sync: "waiting to sync",
  request: "Request",
  request_expired: "Expired",
  request_aria: "request waiting for your answer",
  request_expired_aria: "request expired without an answer",
  request_waiting: "a request waiting for your answer",
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
  test("with week numbers on, the head corner names the week", () => {
    const grid = draw({ settings: { ...settings, show_week_numbers: true } });
    const cell = grid.querySelector(".cal-head-corner .cal-weeknum");
    expect(cell.textContent).toBe("42");
    expect(cell.getAttribute("aria-label")).toBe("Week 42");
    expect(cell.getAttribute("role")).toBe("img");
  });

  test("a Sunday-start week is numbered by its Monday, and a day by itself", () => {
    const sundayWeek = Array.from({ length: 7 }, (_, k) => addDays("2026-10-18", k));
    const on = { ...settings, show_week_numbers: true };
    expect(draw({ days: sundayWeek, settings: on }).querySelector(".cal-weeknum").textContent).toBe("43");
    expect(draw({ view: "day", days: ["2026-10-18"], settings: on }).querySelector(".cal-weeknum").textContent).toBe("42");
  });

  test("with week numbers off, the head corner is empty", () => {
    const grid = draw();
    expect(grid.querySelector(".cal-weeknum")).toBeNull();
    expect(grid.querySelector(".cal-head-corner").innerHTML).toBe("");
  });

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
    expect(grid.querySelector('[data-event-id="booking-1"]').getAttribute("style")).toContain("--cal-ev:var(--color-booking)");
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

  test("the folded night still labels 07:00, where the hours start", () => {
    const hours = [...draw().querySelectorAll(".cal-hour")].map((el) => el.textContent);
    expect(hours[0]).toBe("07:00");
  });

  test("a narrow event's hover lift stays under the column's chip and above its events", () => {
    const five = ["a", "b", "c", "d", "e"].map((id) => timed(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
    const grid = draw({ events: five, width: 1400 });
    const col = grid.querySelector('.cal-col[data-day="2026-10-14"]');
    const lift = Number(col.getAttribute("style").match(/--cal-lift:(\d+)/)[1]);
    const z = (el) => Number(el.getAttribute("style").match(/--z:(\d+)/)[1]);
    const shown = [...col.querySelectorAll(".cal-ev")];
    expect(shown.length).toBeGreaterThan(0);
    expect(lift).toBeLessThan(z(col.querySelector(".cal-more")));
    expect(shown.filter((el) => z(el) >= lift)).toEqual([]);
  });

  test("a title needing two lines in an hour keeps both and drops the time rather than being cut", () => {
    const title = "Quarterly planning with the whole team";
    const block = draw({ events: [timed("event-1", title, "2026-10-12T14:00", "2026-10-12T15:00")] }).querySelector('[data-event-id="event-1"]');
    expect(block.getAttribute("style")).toContain("--cal-lines:2");
    expect(block.querySelector(".cal-ev-time")).toBeNull();
  });

  test("a one-line title in an hour keeps its time line", () => {
    const block = draw({ events: [timed("event-1", "Retro", "2026-10-12T14:00", "2026-10-12T15:00")] }).querySelector('[data-event-id="event-1"]');
    expect(block.querySelector(".cal-ev-time").textContent).toBe("14:00–15:00");
    expect(block.getAttribute("style")).toContain("--cal-lines:1");
  });

  // 56px of axis and seven 60px columns: each lone event is 54px wide.
  const narrow = 56 + 7 * 60;

  test("a word too wide for a narrow block truncates on its own line, never breaking inside", () => {
    const block = draw({ events: [timed("event-1", "Strategy workshop", "2026-10-14T09:00", "2026-10-14T10:30")], width: narrow }).querySelector('[data-event-id="event-1"]');
    const words = [...block.querySelectorAll(".cal-ev-title .cal-ev-word")].map((el) => el.textContent);
    expect(words).toEqual(["Strategy", "workshop"]);
    // Counted as one line per word, the title fits above the time line; split
    // mid-word it took four lines and pushed the time out.
    expect(block.querySelector(".cal-ev-time").textContent).toBe("09:00");
    expect(block.getAttribute("style")).toContain("--cal-lines:3");
  });

  test("a word that fits is left as plain text", () => {
    const block = draw({ events: [timed("event-1", "Retro", "2026-10-14T09:00", "2026-10-14T12:30")], width: narrow }).querySelector('[data-event-id="event-1"]');
    expect(block.querySelector(".cal-ev-word")).toBeNull();
    expect(block.querySelector(".cal-ev-title").textContent).toBe("Retro");
  });

  test("a one-row block too narrow for title and time drops the time so the title shows", () => {
    const block = draw({ events: [timed("event-1", "Hiring sync", "2026-10-14T10:15", "2026-10-14T10:45")], width: narrow }).querySelector('[data-event-id="event-1"]');
    expect(block.classList.contains("is-short")).toBe(true);
    expect(block.querySelector(".cal-ev-time")).toBeNull();
    expect(block.querySelector(".cal-ev-title").textContent).toBe("Hiring sync");
  });

  test("a one-row block drops its time before it cuts the title short", () => {
    const block = draw({ events: [timed("event-1", "Weekly planning with design", "2026-10-14T10:15", "2026-10-14T10:45")] }).querySelector('[data-event-id="event-1"]');
    expect(block.classList.contains("is-short")).toBe(true);
    expect(block.querySelector(".cal-ev-time")).toBeNull();
    expect(block.querySelector(".cal-ev-title").textContent).toBe("Weekly planning with design");
  });

  test("a one-row block with room for both keeps its time beside the title", () => {
    const block = draw({ events: [timed("event-1", "Hiring sync", "2026-10-14T10:15", "2026-10-14T10:45")] }).querySelector('[data-event-id="event-1"]');
    expect(block.classList.contains("is-short")).toBe(true);
    expect(block.querySelector(".cal-ev-time").textContent).toBe("10:15");
  });

  test("compact density uses 38px hours", () => {
    expect(draw({ settings: { ...settings, density: "compact" } }).querySelector(".cal-grid").getAttribute("style")).toContain("--cal-hour:38px");
  });
  test("a request carries its own class, a Request flag and says it waits for an answer", () => {
    const grid = draw({
      events: [timed("booking-1", "Anna · Intro", "2026-10-15T11:00", "2026-10-15T13:00", { kind: "booking", colour: "booking", request: true })],
    });
    const block = grid.querySelector('[data-event-id="booking-1"]');
    expect(block.classList.contains("is-booking")).toBe(true);
    expect(block.classList.contains("is-request")).toBe(true);
    expect(block.classList.contains("is-expired")).toBe(false);
    expect(block.querySelector(".cal-ev-title .cal-ev-request").textContent).toBe("Request");
    expect(block.getAttribute("aria-label")).toBe("Anna · Intro, request waiting for your answer, Thu 15 Oct, 11:00–13:00");
  });

  test("an expired request is marked expired, flagged so and says it was never answered", () => {
    const grid = draw({
      events: [timed("booking-2", "Ben · Intro", "2026-10-15T13:00", "2026-10-15T15:00", { kind: "booking", colour: "booking", expired: true })],
    });
    const block = grid.querySelector('[data-event-id="booking-2"]');
    expect(block.classList.contains("is-request")).toBe(true);
    expect(block.classList.contains("is-expired")).toBe(true);
    expect(block.querySelector(".cal-ev-request").textContent).toBe("Expired");
    expect(block.getAttribute("aria-label")).toContain("request expired without an answer");
    expect(block.getAttribute("aria-label")).not.toContain("waiting for your answer");
  });

  test("an expired request is not drawn or announced as free, though it carries the free flag", () => {
    const grid = draw({
      events: [timed("booking-4", "Dan · Intro", "2026-10-15T09:00", "2026-10-15T10:00", { kind: "booking", colour: "booking", expired: true, free: true })],
    });
    const block = grid.querySelector('[data-event-id="booking-4"]');
    expect(block.classList.contains("is-free")).toBe(false);
    expect(block.getAttribute("aria-label")).not.toContain("shown as free");
  });

  test("an all-day request has the flag, the class and the aria word; its +N says a request waits", () => {
    const day = (id, extra = {}) => normaliseEvent({ id, kind: "booking", title: id, all_day: true, start: "2026-10-14", end: "2026-10-15", colour: "booking", ...extra });
    const grid = draw({ events: [day("booking-r", { request: true }), day("booking-x", { expired: true })] });
    const bar = grid.querySelector('.cal-adbar[data-event-id="booking-r"]');
    expect(bar.classList.contains("is-request")).toBe(true);
    expect(bar.querySelector(".cal-ev-request").textContent).toBe("Request");
    expect(bar.getAttribute("aria-label")).toContain("request waiting for your answer");
    const lapsed = grid.querySelector('.cal-adbar[data-event-id="booking-x"]');
    expect(lapsed.classList.contains("is-expired")).toBe(true);
    expect(lapsed.querySelector(".cal-ev-request").textContent).toBe("Expired");

    const crowd = ["a", "b", "c", "d"].map((id) => day(`booking-${id}`, { request: true }));
    const more = draw({ events: crowd }).querySelector(".cal-admore");
    expect(more.classList.contains("is-warn")).toBe(true);
    expect(more.getAttribute("aria-label")).toContain("a request waiting for your answer");
  });

  test("a request that also expired says only that it expired", () => {
    const grid = draw({ events: [timed("booking-6", "Eve · Intro", "2026-10-15T09:00", "2026-10-15T10:00", { kind: "booking", colour: "booking", request: true, expired: true })] });
    const label = grid.querySelector('[data-event-id="booking-6"]').getAttribute("aria-label");
    expect(label).toContain("request expired without an answer");
    expect(label).not.toContain("waiting for your answer");
  });

  test("a request's flag and wider edge count against its title's room", () => {
    const grid = (extra) =>
      draw({ width: 1000, events: [timed("booking-7", "Guest with a long name", "2026-10-15T09:00", "2026-10-15T10:15", { kind: "booking", colour: "booking", ...extra })] }).querySelector(
        '[data-event-id="booking-7"]',
      );
    // Without the flag the title takes two lines and the time row still fits.
    expect(grid({}).querySelector(".cal-ev-time")).not.toBeNull();
    // The flag and the wider edge push it to three lines, which leaves no room for the time.
    const request = grid({ request: true });
    expect(request.querySelector(".cal-ev-time")).toBeNull();
    expect(request.style.getPropertyValue("--cal-lines")).toBe("3");
  });

  test("a short request keeps its title's first word: the flag is a corner badge", () => {
    // One hour is 48px at the default zoom: room for one title line beside the time.
    const block = draw({ width: 1440, events: [timed("booking-8", "Anna Kowalska · Intro", "2026-10-15T09:00", "2026-10-15T10:00", { kind: "booking", colour: "booking", request: true })] }).querySelector(
      '[data-event-id="booking-8"]',
    );
    const badge = block.querySelector(".cal-ev-request");
    expect(badge.classList.contains("is-compact")).toBe(true);
    expect(badge.textContent).toBe("");
    expect(badge.getAttribute("aria-hidden")).toBe("true");
    expect(block.querySelector(".cal-ev-title").textContent.startsWith("Anna")).toBe(true);
    expect(block.getAttribute("aria-label")).toContain("request waiting for your answer");
  });

  test("a tall request keeps the inline Request pill", () => {
    const block = draw({ width: 1440, events: [timed("booking-9", "Anna Kowalska · Intro", "2026-10-15T09:00", "2026-10-15T11:00", { kind: "booking", colour: "booking", request: true })] }).querySelector(
      '[data-event-id="booking-9"]',
    );
    expect(block.querySelector(".cal-ev-title .cal-ev-request").textContent).toBe("Request");
    expect(block.querySelector(".is-compact")).toBeNull();
  });

  test("a plain booking has no flag", () => {
    const grid = draw({ events: [timed("booking-3", "Cleo · Intro", "2026-10-15T15:00", "2026-10-15T16:00", { kind: "booking", colour: "booking" })] });
    expect(grid.querySelector('[data-event-id="booking-3"] .cal-ev-request')).toBeNull();
  });

  test("a request in a crowd stays on the grid while plain events fold behind the chip", () => {
    const plain = ["a", "b", "c", "d"].map((id) => timed(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
    // "z-request" sorts last by id, so without its request it would be the first to fold.
    const request = timed("z-request", "Zoe · Intro", "2026-10-14T13:00", "2026-10-14T14:00", { kind: "booking", colour: "booking", request: true });
    const grid = draw({ events: [...plain, request] });
    const chip = grid.querySelector(".cal-more");
    expect(chip).not.toBeNull();
    expect(chip.dataset.hidden.split(",")).not.toContain("z-request");
    expect(grid.querySelector('.cal-col [data-event-id="z-request"]')).not.toBeNull();
    expect(chip.classList.contains("is-warn")).toBe(false);
  });

  test("requests forced behind the chip mark it and say a request is waiting", () => {
    const requests = ["a", "b", "c", "d", "e"].map((id) => timed(`booking-${id}`, `Guest ${id}`, "2026-10-14T13:00", "2026-10-14T14:00", { kind: "booking", colour: "booking", request: true }));
    const chip = draw({ events: requests }).querySelector(".cal-more");
    expect(chip.classList.contains("is-warn")).toBe(true);
    expect(chip.getAttribute("aria-label")).toContain("a request waiting for your answer");
    expect(chip.getAttribute("aria-label")).not.toContain("waiting to sync");
  });

  test("expired requests fold like any event and leave the chip unmarked", () => {
    const expired = ["a", "b", "c", "d", "e"].map((id) => timed(`booking-${id}`, `Guest ${id}`, "2026-10-14T13:00", "2026-10-14T14:00", { kind: "booking", colour: "booking", expired: true }));
    const chip = draw({ events: expired }).querySelector(".cal-more");
    expect(chip.classList.contains("is-warn")).toBe(false);
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

test("renderList flags a request", () => {
  const container = document.createElement("div");
  container.innerHTML = renderList(
    [timed("booking-1", "Anna · Intro", "2026-10-14T09:00", "2026-10-14T09:30", { kind: "booking", request: true }), timed("event-1", "Standup", "2026-10-14T10:00", "2026-10-14T10:15")],
    { strings, timeFormat: "24h", label: "Events at this time" },
  );
  expect(container.querySelector('[data-event-id="booking-1"] .cal-list-flag').textContent).toBe("Request");
  expect(container.querySelector('[data-event-id="event-1"] .cal-list-flag')).toBeNull();
});

describe("dateLabel", () => {
  const french = {
    weekdays: ["lun.", "mar.", "mer.", "jeu.", "ven.", "sam.", "dim."],
    months: ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."],
    first_of_month: "1er",
  };

  test("writes the first of the month as the ordinal the server sends", () => {
    expect(dateLabel("2026-10-01", french)).toBe("jeu. 1er oct.");
  });

  test("writes every other day as a plain number", () => {
    expect(dateLabel("2026-10-02", french)).toBe("ven. 2 oct.");
    expect(dateLabel("2026-10-01", strings)).toBe("Thu 1 Oct");
  });
});

describe("renderGrid metrics", () => {
  const call = [timed("event-1", "Call", "2026-10-14T11:00", "2026-10-14T11:05")];
  const trip = [normaliseEvent({ id: "event-2", kind: "event", title: "Trip", all_day: true, start: "2026-10-14", end: "2026-10-15", colour: "calendar-sage", free: false, attention: false })];

  test("without metrics a five-minute event is drawn 20px high", () => {
    const grid = draw({ events: call });
    expect(grid.querySelector('[data-event-id="event-1"]').style.height).toBe("20px");
  });

  test("with phone metrics a five-minute event is drawn 24px high", () => {
    const grid = draw({ events: call, metrics: metricsFor(true) });
    expect(grid.querySelector('[data-event-id="event-1"]').style.height).toBe("24px");
  });

  test("without metrics all-day rows are 22px", () => {
    const grid = draw({ events: trip });
    expect(grid.querySelector(".cal-allday").getAttribute("style")).toContain("repeat(1, 22px)");
    expect(grid.querySelector(".cal-grid").getAttribute("style")).toContain("--cal-allday-row:22px");
  });

  test("with phone metrics all-day rows are 32px, and the bars are told so", () => {
    const grid = draw({ events: trip, metrics: metricsFor(true) });
    expect(grid.querySelector(".cal-allday").getAttribute("style")).toContain("repeat(1, 32px)");
    expect(grid.querySelector(".cal-grid").getAttribute("style")).toContain("--cal-allday-row:32px");
  });
});
