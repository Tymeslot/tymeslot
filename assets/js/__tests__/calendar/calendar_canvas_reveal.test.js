/**
 * Tests for the search reveal in the CalendarCanvas hook
 * (hooks/calendar_canvas/reveal.js): an event drawn in view, one behind a
 * time-grid, all-day or month "+N", one in another week, one in the folded
 * night, the phone's views, the six-second give-up, and the command bar's
 * search rows starting it. Today is Wednesday 14 October 2026.
 */
import { afterEach, expect, test, vi } from "vitest";
import { event, mockViewport, mountHook, payload, pushes, settings, unmountAll } from "./canvas_harness.js";
import { mountWithBar, result } from "./command_fixtures.js";

const MISSED = "That event isn't in view any more.";
const withStrings = (hook) => {
  hook.strings = { ...hook.strings, reveal_missed: MISSED };
};
const tick = async () => {
  for (let i = 0; i < 3; i++) await Promise.resolve();
};
const opened = (hook) => pushes(hook, "calendar:open");

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

test("an event drawn in view opens", async () => {
  const { hook } = mountHook();
  hook.revealEvent({ ids: ["event-2"], date: "2026-10-14", startMin: 840, allDay: false });
  await tick();
  expect(opened(hook)).toEqual([{ id: "event-2" }]);
});

test("an event hidden in a time-grid cluster opens from the chip's list, so focus goes back to the chip", async () => {
  const five = ["a", "b", "c", "d", "e"].map((id) => event(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
  const { el, hook } = mountHook(payload({ events: five }));
  const hidden = el.querySelector(".cal-more").dataset.hidden.split(",")[0];

  hook.revealEvent({ ids: [hidden], date: "2026-10-14", startMin: 780, allDay: false });
  await tick();

  expect(opened(hook)).toEqual([{ id: hidden }]);
  expect(hook.returnTo).toMatchObject({ attr: "data-more" });
});

test("an all-day event behind the lane's +N opens from its list", async () => {
  const holidays = ["a", "b", "c", "d", "e"].map((k) => event(`event-${k}`, `Holiday ${k}`, "2026-10-15", "2026-10-16", { all_day: true }));
  const { el, hook } = mountHook(payload({ events: holidays }));
  const hidden = holidays.map((h) => h.id).find((id) => !el.querySelector(`.cal-adbar[data-event-id="${id}"]`));

  hook.revealEvent({ ids: [hidden], date: "2026-10-15", startMin: null, allDay: true });
  await tick();

  expect(opened(hook)).toEqual([{ id: hidden }]);
  expect(hook.returnTo).toMatchObject({ attr: "data-allday-more" });
});

test("in month an event behind a day's +N opens from that day's list", async () => {
  const crowd = ["a", "b", "c", "d", "e"].map((k) => event(`event-${k}`, `Call ${k}`, `2026-10-20T1${k.charCodeAt(0) - 97}:00`, `2026-10-20T1${k.charCodeAt(0) - 97}:30`));
  const { el, hook } = mountHook(payload({ view: "month", range: { from: "2026-08-31", to: "2026-12-07" }, events: crowd }));
  const hidden = crowd.map((c) => c.id).find((id) => !el.querySelector(`.cal-mchip[data-event-id="${id}"]`));

  hook.revealEvent({ ids: [hidden], date: "2026-10-20", startMin: 840, allDay: false });
  await tick();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "month", date: "2026-10-20" }]);
  expect(opened(hook)).toEqual([{ id: hidden }]);
  expect(hook.returnTo).toMatchObject({ attr: "data-month-more" });
});

test("an event in another week waits for the server's payload, then opens", async () => {
  const { hook, handlers } = mountHook();
  hook.revealEvent({ ids: ["event-9"], date: "2026-11-04", startMin: 540, allDay: false });
  await tick();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-11-04" }]);
  expect(opened(hook)).toEqual([]);

  handlers["calendar:events"](payload({ date: "2026-11-04", range: { from: "2026-10-26", to: "2026-11-16" }, events: [event("event-9", "Dentist", "2026-11-04T09:00", "2026-11-04T09:30")] }));
  await tick();

  expect(opened(hook)).toEqual([{ id: "event-9" }]);
});

test("an event in the folded early hours unfolds the night first", async () => {
  const early = event("event-5", "Early run", "2026-10-15T06:00", "2026-10-15T06:45");
  const { el, hook } = mountHook(payload({ settings: { ...settings, fold_night: true }, events: [early] }));
  expect(el.querySelector('[data-event-id="event-5"]')).toBeNull();

  hook.revealEvent({ ids: ["event-5"], date: "2026-10-15", startMin: 360, allDay: false });
  await tick();

  expect(hook.nightOpen).toBe(true);
  expect(opened(hook)).toEqual([{ id: "event-5" }]);
});

test("on a phone the 3-day view is kept", async () => {
  mockViewport(true);
  const { hook } = mountHook(payload({ view: "three_day" }));
  hook.revealEvent({ ids: ["event-3"], date: "2026-10-15", startMin: 720, allDay: false });
  await tick();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "three_day", date: "2026-10-15" }]);
  expect(opened(hook)).toEqual([{ id: "event-3" }]);
});

test("a weekend event in a week without weekends is revealed in the day view", async () => {
  const sat = event("event-sat", "Market", "2026-10-17T10:00", "2026-10-17T11:00");
  const { hook } = mountHook(payload({ settings: { ...settings, show_weekends: false }, events: [sat] }));

  hook.revealEvent({ ids: ["event-sat"], date: "2026-10-17", startMin: 600, allDay: false });
  await tick();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-17" }]);
});

test("a date the shown period does not draw ends with the notice, not silence", async () => {
  const { hook } = mountHook(payload({ settings: { ...settings, show_weekends: false } }));
  withStrings(hook);
  const reveal = { ids: ["event-sat"], date: "2026-10-17", view: "week", opened: hook.lastOpened };
  hook.reveal = reveal;

  hook.tryReveal(reveal, false);

  expect(document.getElementById("calendar-notice").textContent).toContain(MISSED);
});

test("after six seconds without the event the hook gives up with a notice", async () => {
  vi.useFakeTimers();
  const { hook } = mountHook();
  withStrings(hook);

  hook.revealEvent({ ids: ["event-99"], date: "2026-10-14", startMin: 600, allDay: false });
  await tick();
  vi.advanceTimersByTime(5999);
  expect(document.getElementById("calendar-notice")).toBeNull();
  vi.advanceTimersByTime(1);

  expect(document.getElementById("calendar-notice").textContent).toContain(MISSED);
  expect(hook.reveal).toBeNull();
});

test("a reveal that found its event never gives up later", async () => {
  vi.useFakeTimers();
  const { hook } = mountHook();
  withStrings(hook);

  hook.revealEvent({ ids: ["event-2"], date: "2026-10-14", startMin: 840, allDay: false });
  await tick();
  vi.advanceTimersByTime(6000);

  expect(document.getElementById("calendar-notice")).toBeNull();
});

test("choosing a search row in the command bar reveals its event", async () => {
  const { hook, results } = mountWithBar();
  document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true, cancelable: true }));
  results.innerHTML = result("event-2", "2026-10-14", 840);

  document.getElementById("calendar-command-row-event-2").click();
  await tick();

  expect(document.getElementById("calendar-command").hasAttribute("data-open")).toBe(false);
  expect(opened(hook)).toEqual([{ id: "event-2" }]);
});

test("a target in an adjacent loaded week: calendar:goto reaches the server before calendar:open", async () => {
  const next = event("event-9", "Next week", "2026-10-21T09:00", "2026-10-21T10:00");
  const { hook } = mountHook(payload({ events: [next] }));
  hook.revealEvent({ ids: ["event-9"], date: "2026-10-21", startMin: 540, allDay: false });
  await tick();

  const names = hook.pushEventTo.mock.calls.map((call) => call[1]);
  expect(names.indexOf("calendar:goto")).toBeGreaterThanOrEqual(0);
  expect(names.indexOf("calendar:goto")).toBeLessThan(names.indexOf("calendar:open"));
});

test("the preview opens after the time grid's scroll is applied", async () => {
  const late = event("event-9", "Late", "2026-10-14T15:00", "2026-10-14T16:00");
  const { el, hook } = mountHook(payload({ events: [late] }));
  const original = hook.open.bind(hook);
  let atOpen = null;
  hook.open = (id, node) => {
    atOpen = el.querySelector("[data-scroll]").scrollTop;
    return original(id, node);
  };
  hook.revealEvent({ ids: ["event-9"], date: "2026-10-14", startMin: 900, allDay: false });
  await tick();

  expect(atOpen).toBe(el.querySelector("[data-scroll]").scrollTop);
  expect(opened(hook)).toEqual([{ id: "event-9" }]);
});

test("day view and agenda find their event", async () => {
  for (const view of ["day", "agenda"]) {
    const { hook } = mountHook(payload({ view, range: { from: "2026-09-16", to: "2026-12-09" }, events: [event("event-4", "Call", "2026-10-14T10:00", "2026-10-14T11:00")] }));
    hook.revealEvent({ ids: ["event-4"], date: "2026-10-14", startMin: 600, allDay: false });
    await tick();
    expect(opened(hook)).toEqual([{ id: "event-4" }]);
    unmountAll();
  }
});

test("a phone's month keeps month and opens the event from the chosen day's list", async () => {
  mockViewport(true);
  const { hook } = mountHook(payload({ view: "month", range: { from: "2026-08-31", to: "2026-12-07" }, events: [event("event-4", "Call", "2026-10-14T10:00", "2026-10-14T11:00")] }));
  hook.revealEvent({ ids: ["event-4"], date: "2026-10-14", startMin: 600, allDay: false });
  await tick();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "month", date: "2026-10-14" }]);
  expect(opened(hook)).toEqual([{ id: "event-4" }]);
});

test("a booking hit is found by the first id that is drawn", async () => {
  const { hook } = mountHook(payload({ events: [event("booking-7", "Intro call", "2026-10-14T10:00", "2026-10-14T11:00")] }));
  hook.revealEvent({ ids: ["event-7", "booking-7"], date: "2026-10-14", startMin: 600, allDay: false });
  await tick();
  expect(opened(hook)).toEqual([{ id: "booking-7" }]);
});

test("a second reveal replaces the first", async () => {
  vi.useFakeTimers();
  const { hook } = mountHook();
  withStrings(hook);
  hook.revealEvent({ ids: ["event-99"], date: "2026-10-14", startMin: 600, allDay: false });
  hook.revealEvent({ ids: ["event-2"], date: "2026-10-14", startMin: 840, allDay: false });
  await tick();
  vi.advanceTimersByTime(6000);

  expect(opened(hook)).toEqual([{ id: "event-2" }]);
  expect(document.getElementById("calendar-notice")).toBeNull();
});

test("destroying the hook during a reveal clears its timer", () => {
  vi.useFakeTimers();
  const { hook } = mountHook();
  withStrings(hook);
  hook.revealEvent({ ids: ["event-99"], date: "2026-10-14", startMin: 600, allDay: false });
  hook.destroyReveal();
  vi.advanceTimersByTime(7000);

  expect(document.getElementById("calendar-notice")).toBeNull();
  expect(hook.reveal).toBeNull();
});

test("the reveal ends silently when the organiser moves to another period", async () => {
  vi.useFakeTimers();
  const { hook, handlers } = mountHook();
  withStrings(hook);
  hook.revealEvent({ ids: ["event-9"], date: "2026-11-04", startMin: 540, allDay: false });
  hook.navigate({ view: "week", date: "2026-12-02" });
  handlers["calendar:events"](payload({ date: "2026-12-02", range: { from: "2026-11-23", to: "2026-12-14" }, events: [] }));
  await tick();
  vi.advanceTimersByTime(6000);

  expect(hook.reveal).toBeNull();
  expect(document.getElementById("calendar-notice")).toBeNull();
});

test("the reveal ends silently when another preview is opened meanwhile", async () => {
  vi.useFakeTimers();
  const { hook } = mountHook();
  withStrings(hook);
  hook.revealEvent({ ids: ["event-99"], date: "2026-10-14", startMin: 600, allDay: false });
  hook.lastOpened = "event-3";
  hook.afterReveal();
  await tick();
  vi.advanceTimersByTime(6000);

  expect(hook.reveal).toBeNull();
  expect(document.getElementById("calendar-notice")).toBeNull();
});
