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
const opened = (hook) => pushes(hook, "calendar:open");

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

test("an event drawn in view opens", () => {
  const { hook } = mountHook();
  hook.revealEvent({ ids: ["event-2"], date: "2026-10-14", startMin: 840, allDay: false });
  expect(opened(hook)).toEqual([{ id: "event-2" }]);
});

test("an event hidden in a time-grid cluster opens from the chip's list, so focus goes back to the chip", () => {
  const five = ["a", "b", "c", "d", "e"].map((id) => event(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
  const { el, hook } = mountHook(payload({ events: five }));
  const hidden = el.querySelector(".cal-more").dataset.hidden.split(",")[0];

  hook.revealEvent({ ids: [hidden], date: "2026-10-14", startMin: 780, allDay: false });

  expect(opened(hook)).toEqual([{ id: hidden }]);
  expect(hook.returnTo).toMatchObject({ attr: "data-more" });
});

test("an all-day event behind the lane's +N opens from its list", () => {
  const holidays = ["a", "b", "c", "d", "e"].map((k) => event(`event-${k}`, `Holiday ${k}`, "2026-10-15", "2026-10-16", { all_day: true }));
  const { el, hook } = mountHook(payload({ events: holidays }));
  const hidden = holidays.map((h) => h.id).find((id) => !el.querySelector(`.cal-adbar[data-event-id="${id}"]`));

  hook.revealEvent({ ids: [hidden], date: "2026-10-15", startMin: null, allDay: true });

  expect(opened(hook)).toEqual([{ id: hidden }]);
  expect(hook.returnTo).toMatchObject({ attr: "data-allday-more" });
});

test("in month an event behind a day's +N opens from that day's list", () => {
  const crowd = ["a", "b", "c", "d", "e"].map((k) => event(`event-${k}`, `Call ${k}`, `2026-10-20T1${k.charCodeAt(0) - 97}:00`, `2026-10-20T1${k.charCodeAt(0) - 97}:30`));
  const { el, hook } = mountHook(payload({ view: "month", range: { from: "2026-08-31", to: "2026-12-07" }, events: crowd }));
  const hidden = crowd.map((c) => c.id).find((id) => !el.querySelector(`.cal-mchip[data-event-id="${id}"]`));

  hook.revealEvent({ ids: [hidden], date: "2026-10-20", startMin: 840, allDay: false });

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "month", date: "2026-10-20" }]);
  expect(opened(hook)).toEqual([{ id: hidden }]);
  expect(hook.returnTo).toMatchObject({ attr: "data-month-more" });
});

test("an event in another week waits for the server's payload, then opens", () => {
  const { hook, handlers } = mountHook();
  hook.revealEvent({ ids: ["event-9"], date: "2026-11-04", startMin: 540, allDay: false });

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-11-04" }]);
  expect(opened(hook)).toEqual([]);

  handlers["calendar:events"](payload({ date: "2026-11-04", range: { from: "2026-10-26", to: "2026-11-16" }, events: [event("event-9", "Dentist", "2026-11-04T09:00", "2026-11-04T09:30")] }));

  expect(opened(hook)).toEqual([{ id: "event-9" }]);
});

test("an event in the folded early hours unfolds the night first", () => {
  const early = event("event-5", "Early run", "2026-10-15T06:00", "2026-10-15T06:45");
  const { el, hook } = mountHook(payload({ settings: { ...settings, fold_night: true }, events: [early] }));
  expect(el.querySelector('[data-event-id="event-5"]')).toBeNull();

  hook.revealEvent({ ids: ["event-5"], date: "2026-10-15", startMin: 360, allDay: false });

  expect(hook.nightOpen).toBe(true);
  expect(opened(hook)).toEqual([{ id: "event-5" }]);
});

test("on a phone the 3-day view is kept", () => {
  mockViewport(true);
  const { hook } = mountHook(payload({ view: "three_day" }));
  hook.revealEvent({ ids: ["event-3"], date: "2026-10-15", startMin: 720, allDay: false });

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "three_day", date: "2026-10-15" }]);
  expect(opened(hook)).toEqual([{ id: "event-3" }]);
});

test("after six seconds without the event the hook gives up with a notice", () => {
  vi.useFakeTimers();
  const { hook, live } = mountHook();
  withStrings(hook);

  hook.revealEvent({ ids: ["event-99"], date: "2026-10-14", startMin: 600, allDay: false });
  vi.advanceTimersByTime(5999);
  expect(document.getElementById("calendar-notice")).toBeNull();
  vi.advanceTimersByTime(1);

  expect(document.getElementById("calendar-notice").textContent).toContain(MISSED);
  expect(live.textContent).toBe(MISSED);
  expect(hook.reveal).toBeNull();
});

test("a reveal that found its event never gives up later", () => {
  vi.useFakeTimers();
  const { hook } = mountHook();
  withStrings(hook);

  hook.revealEvent({ ids: ["event-2"], date: "2026-10-14", startMin: 840, allDay: false });
  vi.advanceTimersByTime(6000);

  expect(document.getElementById("calendar-notice")).toBeNull();
});

test("choosing a search row in the command bar reveals its event", () => {
  const { hook, results } = mountWithBar();
  document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "k", ctrlKey: true, bubbles: true, cancelable: true }));
  results.innerHTML = result("event-2", "2026-10-14", 840);

  document.getElementById("calendar-command-row-event-2").click();

  expect(document.getElementById("calendar-command").hasAttribute("data-open")).toBe(false);
  expect(opened(hook)).toEqual([{ id: "event-2" }]);
});
