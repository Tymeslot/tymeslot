/**
 * Tests for "Open for booking" in the CalendarCanvas hook
 * (hooks/calendar_canvas/opening.js with the create mixin): the kind
 * switch, the opening's chips, Save and the server's reply, a lost reply,
 * and C's slot that is not already bookable. The week is Mon 12 to Sun 18
 * October 2026; now is Wednesday 14, 08:30.
 */
import { afterEach, expect, test, vi } from "vitest";
import { addDays, makeScale } from "../../calendar/time.js";
import { mountHook, payload, pushes, settings, unmountAll } from "./canvas_harness.js";

const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const meetingTypes = [
  { id: 11, name: "Intro call", duration: 30 },
  { id: 12, name: "Deep dive", duration: 90 },
];
const withTypes = () => payload({ settings: { ...settings, meeting_types: meetingTypes } });
const popover = () => document.getElementById("calendar-quick-create");
const field = () => document.getElementById("calendar-qc-field");
const q = (selector) => popover().querySelector(selector);
const notice = () => document.getElementById("calendar-notice");
const drawn = (el) => el.querySelector("[data-draft-id]");
const key = (target, k, extra = {}) => target.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...extra }));
const reply = (hook, name, answer) => hook.pushEventTo.mock.calls.find(([, pushed]) => pushed === name)[3](answer);
const toOpen = () => q('[data-qc-kind="open"]').click();

// A click on Thursday 15 October, 09:00.
function open(first = withTypes()) {
  const mounted = mountHook(first);
  mounted.hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  const column = mounted.el.querySelector('.cal-col[data-day="2026-10-15"]');
  column.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: 350, clientY: 52 * 9 + 10 }));
  return mounted;
}

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
});

test("without meeting types quick create has no kind switch", () => {
  open(payload());
  expect(q("[data-qc-kind]")).toBeNull();
  expect(field().hidden).toBe(false);
});

test("Open for booking hides the field and draws the opening under its meeting type", () => {
  const { el, hook } = open();
  field().focus();
  toOpen();

  expect(hook.draft).toMatchObject({ kind: "open", meetingType: 11, repeat: "once" });
  expect(field().hidden).toBe(true);
  expect(q('[data-qc-kind="open"]').getAttribute("aria-pressed")).toBe("true");
  // Focus never stays on the hidden field.
  expect(document.activeElement).toBe(q('[data-qc-kind="open"]'));
  expect(q('[data-qc-pick="start"]').textContent).toBe("09:00");
  expect(q('[data-qc-pick="end"]').textContent).toBe("09:30");
  expect(drawn(el).querySelector(".cal-ev-title").textContent).toBe("Open for Intro call");
  expect(drawn(el).classList.contains("is-opening")).toBe(true);
});

test("another meeting type renames the opening and lengthens it to one meeting", () => {
  const { el } = open();
  toOpen();
  const select = q('[data-qc-input="meetingType"]');
  select.value = "12";
  select.dispatchEvent(new Event("change", { bubbles: true }));

  expect(q('[data-qc-pick="end"]').textContent).toBe("10:30");
  expect(drawn(el).querySelector(".cal-ev-title").textContent).toBe("Open for Deep dive");
});

test("Save sends the opening, not an event, and waits for the reply", () => {
  const { hook } = open();
  toOpen();
  q('[data-qc-repeat="weekly"]').click();
  q("[data-qc-save]").click();

  expect(pushes(hook, "calendar:open_booking")).toEqual([{ draft: hook.draft.id, meeting_type: 11, start: "2026-10-15T09:00", end: "2026-10-15T09:30", repeat: "weekly" }]);
  expect(pushes(hook, "calendar:create")).toEqual([]);
  expect(q("[data-qc-save]").textContent).toBe("Saving…");
  // The locked Save does not send it twice.
  q("[data-qc-save]").click();
  expect(pushes(hook, "calendar:open_booking")).toHaveLength(1);
});

test("accepted, the popover closes and the opening stays drawn until the layer arrives", () => {
  const { el, hook, handlers } = open();
  toOpen();
  q("[data-qc-save]").click();
  reply(hook, "calendar:open_booking", { accepted: true });

  expect(popover()).toBeNull();
  expect(hook.draft).toBeNull();
  expect(drawn(el).querySelector(".cal-ev-title").textContent).toBe("Open for Intro call");

  // An events payload carries no opening, so it stays.
  handlers["calendar:events"](withTypes());
  expect(drawn(el)).not.toBeNull();

  handlers["calendar:bookable"]({ on: true, meeting_type: { id: 11, name: "Intro call" }, windows: [{ start: "2026-10-15T09:00", end: "2026-10-15T09:30" }], next: null, error: false, timezone: "Europe/London" });
  expect(drawn(el)).toBeNull();
});

test("refused, the message shows on the chip it names and the opening stays open", () => {
  const { hook } = open();
  toOpen();
  q("[data-qc-save]").click();
  reply(hook, "calendar:open_booking", { accepted: false, field: "meeting_type", error: "That meeting type can't be opened. Choose another one." });

  expect(q("#calendar-qc-error").textContent).toBe("That meeting type can't be opened. Choose another one.");
  expect(q('[data-qc-input="meetingType"]').getAttribute("aria-invalid")).toBe("true");
  expect(q("[data-qc-save]").disabled).toBe(false);
  expect(hook.draft.kind).toBe("open");
});

test("a refusal with no message falls back to the opening's own", () => {
  const { hook } = open();
  toOpen();
  q("[data-qc-save]").click();
  reply(hook, "calendar:open_booking", undefined);
  expect(q("#calendar-qc-error").textContent).toBe("Couldn't open that time. Please try again.");
});

test("a reply that never comes drops the draft and asks the organiser to check their bookable times", () => {
  vi.useFakeTimers();
  const { el, hook, handlers } = open();
  toOpen();
  q("[data-qc-save]").click();
  vi.advanceTimersByTime(15000);

  expect(popover()).toBeNull();
  expect(drawn(el)).toBeNull();
  expect(notice().textContent).toBe("Couldn't confirm the change. Check your bookable times.");

  const [{ draft }] = pushes(hook, "calendar:open_booking");
  handlers["calendar:create-settled"]({ draft });
  expect(notice()).toBeNull();
});

test("back to Event the field returns and Enter creates an event as before", () => {
  const { hook } = open();
  toOpen();
  q('[data-qc-kind="event"]').click();
  expect(field().hidden).toBe(false);

  field().value = "Lunch";
  field().dispatchEvent(new Event("input", { bubbles: true }));
  key(field(), "Enter");
  expect(pushes(hook, "calendar:create")).toHaveLength(1);
  expect(pushes(hook, "calendar:open_booking")).toEqual([]);
});

test("after C, Open for booking moves the draft once, to the next slot guests cannot book yet", () => {
  const { hook, handlers } = mountHook(withTypes());
  handlers["calendar:bookable"]({
    on: true,
    meeting_type: { id: 11, name: "Intro call" },
    windows: [
      { start: "2026-10-14T08:00", end: "2026-10-14T11:00" },
      { start: "2026-10-14T13:00", end: "2026-10-14T17:00" },
    ],
    next: null,
    error: false,
    timezone: "Europe/London",
  });
  key(document.body, "c");
  expect(q('[data-qc-pick="start"]').textContent).toBe("08:45");

  toOpen();
  // 08:45 is bookable already and 11:00 to 12:00 is "Design review".
  expect(q('[data-qc-pick="date"]').textContent).toBe("Wed 14 Oct");
  expect(q('[data-qc-pick="start"]').textContent).toBe("12:00");

  q('[data-qc-kind="event"]').click();
  toOpen();
  expect(q('[data-qc-pick="start"]').textContent).toBe("12:00");
  expect(hook.draft.origin).toBeNull();
});

test("after C, a start the organiser chose stays when the draft becomes an opening", () => {
  const { hook, handlers } = mountHook(withTypes());
  handlers["calendar:bookable"]({
    on: true,
    meeting_type: { id: 11, name: "Intro call" },
    windows: [{ start: "2026-10-14T08:00", end: "2026-10-14T11:00" }],
    next: null,
    error: false,
    timezone: "Europe/London",
  });
  key(document.body, "c");
  const start = q('[data-qc-input="start"]');
  start.value = "10:00";
  start.dispatchEvent(new Event("change", { bubbles: true }));

  toOpen();
  expect(q('[data-qc-pick="start"]').textContent).toBe("10:00");
  expect(hook.draft.origin).toBeNull();
});

test("after C on a week already past, Open for booking leaves the draft for the server to answer", () => {
  const { hook, handlers } = mountHook(payload({ date: "2026-10-07", settings: { ...settings, meeting_types: meetingTypes } }));
  handlers["calendar:bookable"]({
    on: true,
    meeting_type: { id: 11, name: "Intro call" },
    windows: [{ start: "2026-10-05T09:00", end: "2026-10-05T10:00" }],
    next: null,
    error: false,
    timezone: "Europe/London",
  });
  key(document.body, "c");
  expect(q('[data-qc-pick="date"]').textContent).toBe("Mon 5 Oct");
  expect(q('[data-qc-pick="start"]').textContent).toBe("09:00");

  toOpen();
  expect(q('[data-qc-pick="start"]').textContent).toBe("09:00");
  expect(hook.draft).toMatchObject({ kind: "open", origin: null });
});

const noCalendar = (types) => payload({ settings: { ...settings, calendars: [], default_calendar: null, meeting_types: types } });

test("with no calendar, a new draft starts as Open for booking", () => {
  const { hook } = open(noCalendar(meetingTypes));

  expect(hook.draft.kind).toBe("open");
  expect(field().hidden).toBe(true);
  expect(document.activeElement).toBe(q('[data-qc-kind="open"]'));
  expect(q("[data-qc-save]").disabled).toBe(false);
});

test("with no calendar and no meeting types, Enter and Save send nothing", () => {
  const { hook } = open(noCalendar([]));
  expect(hook.draft.kind).toBe("event");
  expect(q("#calendar-qc-no-calendar")).not.toBeNull();

  field().value = "Lunch";
  field().dispatchEvent(new Event("input", { bubbles: true }));
  key(field(), "Enter");
  q("[data-qc-save]").click();

  expect(pushes(hook, "calendar:create")).toEqual([]);
  expect(hook.draft.status).toBe("editing");
});
