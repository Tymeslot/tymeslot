/**
 * Tests for the CalendarCanvas hook (hooks/calendar_canvas.js): it pulls data
 * on mount, draws from the cache, navigates at once into preloaded periods,
 * and pushes intents back to the LiveComponent.
 */
import { afterEach, expect, test, vi } from "vitest";
import { CalendarCanvas } from "../../hooks/calendar_canvas.js";
import { addDays } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  more: "more",
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

const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: true, time_format: "24h", working_hours: {} };
const event = (id, title, start, end) => ({ id, kind: "event", title, all_day: false, start, end, colour: "calendar-2", free: false, attention: false });

function payload(overrides = {}) {
  return {
    view: "week",
    date: "2026-10-14",
    range: { from: "2026-10-05", to: "2026-10-26" },
    now: "2026-10-14T10:30",
    reset: true,
    settings,
    events: [event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00"), event("event-2", "Planning", "2026-10-21T09:00", "2026-10-21T10:00")],
    ...overrides,
  };
}

const mounted = [];

function mountHook() {
  const el = document.createElement("div");
  el.id = "calendar-canvas";
  el.dataset.view = "week";
  el.dataset.date = "2026-10-14";
  el.dataset.strings = JSON.stringify(strings);
  document.body.appendChild(el);

  const handlers = {};
  const hook = Object.assign(Object.create(CalendarCanvas), {
    el,
    measureWidth: (text) => text.length * 7,
    pushEventTo: vi.fn(),
    handleEvent: (name, callback) => {
      handlers[name] = callback;
    },
  });
  hook.mounted();
  mounted.push(hook);
  return { el, hook, handlers, reply: (data) => hook.pushEventTo.mock.calls[0][3](data) };
}

afterEach(() => {
  while (mounted.length) mounted.pop().destroyed();
  document.body.innerHTML = "";
});

test("asks for data on mount and draws nothing until it arrives", () => {
  const { el, hook } = mountHook();
  const [target, name, params] = hook.pushEventTo.mock.calls[0];
  expect([target, name, params]).toEqual([el, "calendar:ready", {}]);
  expect(el.querySelector(".cal-ev")).toBeNull();
});

test("draws the reply", () => {
  const { el, reply } = mountHook();
  reply(payload());
  expect(el.querySelector('[data-event-id="event-1"]').textContent).toContain("Design review");
  expect(el.getAttribute("aria-busy")).toBe("false");
});

test("navigating into a preloaded week draws it at once", () => {
  const { el, reply } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
  expect(el.querySelector('[data-event-id="event-2"]')).not.toBeNull();
  expect(el.querySelector('[data-event-id="event-1"]')).toBeNull();
});

test("navigating beyond what is loaded shows the skeleton until the server answers", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-11-04" } }));
  expect(el.querySelector(".cal-skeleton")).not.toBeNull();
  expect(el.getAttribute("aria-busy")).toBe("true");

  handlers["calendar:events"](payload({ date: "2026-11-04", range: { from: "2026-10-26", to: "2026-11-16" }, reset: false, events: [] }));
  expect(el.querySelector(".cal-skeleton")).toBeNull();
  expect(el.querySelector(".cal-empty")).not.toBeNull();
});

test("clicking an event asks the server for its preview", () => {
  const { el, hook, reply } = mountHook();
  reply(payload());
  el.querySelector('[data-event-id="event-1"]').click();
  const [, name, params] = hook.pushEventTo.mock.calls.at(-1);
  expect([name, params]).toEqual(["calendar:open", { id: "event-1" }]);
});

test("Enter on a focused event opens it too", () => {
  const { el, hook, reply } = mountHook();
  reply(payload());
  el.querySelector('[data-event-id="event-1"]').dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  expect(hook.pushEventTo.mock.calls.at(-1)[1]).toBe("calendar:open");
});

test("a day header opens that day here and tells the server", () => {
  const { el, hook, reply } = mountHook();
  reply(payload());
  el.querySelector('[data-goto-day="2026-10-15"]').click();
  expect(hook.pushEventTo.mock.calls.at(-1).slice(1, 3)).toEqual(["calendar:goto", { view: "day", date: "2026-10-15" }]);
  expect(el.querySelectorAll(".cal-col")).toHaveLength(1);
});

test("a +N chip opens a list of its cluster", () => {
  const { el, reply } = mountHook();
  const five = ["a", "b", "c", "d", "e"].map((id) => event(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
  reply(payload({ events: five }));
  el.querySelector(".cal-more").click();
  expect(el.querySelectorAll(".cal-list .cal-list-item")).toHaveLength(5);
});

test("settings pushed by the server redraw the grid", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  handlers["calendar:settings"]({ ...settings, density: "compact" });
  expect(el.querySelector(".cal-grid").getAttribute("style")).toContain("--cal-hour:38px");
});

test("the preview closing hands focus back to the event", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.querySelector('[data-event-id="event-1"]').click();
  handlers["calendar:preview-closed"]();
  expect(document.activeElement.dataset.eventId).toBe("event-1");
});

test("the folded night opens on click", () => {
  const { el, reply } = mountHook();
  reply(payload({ events: [event("event-3", "Gym", "2026-10-14T05:00", "2026-10-14T06:00")] }));
  expect(el.querySelector('[data-event-id="event-3"]')).toBeNull();
  el.querySelector(".cal-night").click();
  expect(el.querySelector('[data-event-id="event-3"]')).not.toBeNull();
});

test("the days it draws match the week the server named", () => {
  const { el, reply } = mountHook();
  reply(payload());
  const drawn = [...el.querySelectorAll(".cal-col")].map((col) => col.dataset.day);
  expect(drawn).toEqual(Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k)));
});
