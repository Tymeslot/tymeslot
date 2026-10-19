/**
 * Tests for the CalendarCanvas hook's phone layout of its views
 * (hooks/calendar_canvas/views.js): thumb-sized events and all-day rows, the
 * week strip above Day view, and the month's selected day with its agenda.
 */
import { afterEach, expect, test, vi } from "vitest";
import { block, event, mockViewport, mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

const shortCall = event("event-7", "Call", "2026-10-14T16:00", "2026-10-14T16:05");
const conference = { ...event("event-8", "Conference", "2026-10-14", "2026-10-15"), all_day: true };
const dentist = event("event-9", "Dentist", "2026-10-20T09:00", "2026-10-20T09:30");
// A month payload covers the previous and next months' matrices (Period.window(:month)).
const month = () => payload({ view: "month", range: { from: "2026-08-31", to: "2026-12-07" }, events: [...payload().events, dentist] });
const strip = (el) => el.querySelector(".cal-grid")?.previousElementSibling ?? null;

afterEach(() => {
  unmountAll();
  vi.unstubAllGlobals();
});

test("on a phone a five-minute event is drawn 24px high", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ events: [shortCall] }));

  expect(block(el, "event-7").style.height).toBe("24px");
});

test("on a wide screen a five-minute event keeps the 20px minimum", () => {
  mockViewport(false);
  const { el } = mountHook(payload({ events: [shortCall] }));

  expect(block(el, "event-7").style.height).toBe("20px");
});

test("on a phone all-day rows are 32px high", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ events: [conference] }));

  expect(el.querySelector(".cal-allday").getAttribute("style")).toContain("repeat(1, 32px)");
});

test("on a wide screen all-day rows stay 22px high", () => {
  mockViewport(false);
  const { el } = mountHook(payload({ events: [conference] }));

  expect(el.querySelector(".cal-allday").getAttribute("style")).toContain("repeat(1, 22px)");
});

test("Day view on a phone shows the whole week as a strip above the grid", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ view: "day" }));

  const days = [...strip(el).querySelectorAll("button[data-goto-day]")].map((button) => button.dataset.gotoDay);
  expect(days).toEqual(["2026-10-12", "2026-10-13", "2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18"]);
});

test("tapping a day in the strip opens that day", () => {
  mockViewport(true);
  const { el, hook } = mountHook(payload({ view: "day" }));

  strip(el).querySelector('button[data-goto-day="2026-10-16"]').click();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-16" }]);
  expect(hook.view).toBe("day");
  expect(hook.date).toBe("2026-10-16");
  expect(strip(el).querySelectorAll("button[data-goto-day]")).toHaveLength(7);
});

test("Day view on a wide screen has no strip", () => {
  mockViewport(false);
  const { el } = mountHook(payload({ view: "day" }));

  expect(el.querySelector('[data-goto-day="2026-10-12"]')).toBeNull();
});

test("3 days on a phone have no strip", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ view: "three_day" }));

  expect(el.querySelector('[data-goto-day="2026-10-12"]')).toBeNull();
});

test("on a phone, tapping a month day selects it and lists its events below the grid", () => {
  mockViewport(true);
  const { el, hook } = mountHook(month());
  expect(el.querySelector('[data-event-id="event-9"]')).toBeNull();

  el.querySelector('[data-month-day="2026-10-20"]').click();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "month", date: "2026-10-20" }]);
  expect(hook.view).toBe("month");
  expect(hook.date).toBe("2026-10-20");
  expect(el.querySelector('[data-event-id="event-9"]')).not.toBeNull();
  expect(el.querySelector('[data-event-id="event-1"]')).toBeNull();
});

test("on a wide screen, a month day still opens Day view", () => {
  mockViewport(false);
  const { el, hook } = mountHook(month());

  el.querySelector('[data-month-day="2026-10-20"]').click();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-20" }]);
  expect(hook.view).toBe("day");
});

test("the strip's dots come from the loaded week, not only the day shown", () => {
  mockViewport(true);
  const friday = event("event-10", "Friday call", "2026-10-16T10:00", "2026-10-16T11:00");
  const { el } = mountHook(payload({ view: "day", events: [friday] }));

  const button = (iso) => strip(el).querySelector(`button[data-goto-day="${iso}"]`);
  expect(button("2026-10-16").querySelector(".cal-dot")).not.toBeNull();
  expect(button("2026-10-14").querySelector(".cal-dot")).toBeNull();
});

test("no strip is drawn while the week is not cached", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ view: "day", range: { from: "2026-10-14", to: "2026-10-15" } }));

  expect(el.querySelector(".cal-grid")).not.toBeNull();
  expect(el.querySelector(".cal-strip")).toBeNull();
});
