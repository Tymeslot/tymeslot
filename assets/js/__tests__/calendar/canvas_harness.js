/**
 * Mounts the CalendarCanvas hook in jsdom for the hook tests, already fed
 * a week (Mon 12 to Sun 18 October 2026) with three editable events:
 * "Design review" Wed 11:00 to 12:00, "Planning" Wed 14:00 to 15:00 and
 * "Lunch" Thu 12:00 to 13:00. The night is not folded, so the day starts at
 * y = 0 and an hour is 52px.
 */
import { vi } from "vitest";
import { CalendarCanvas } from "../../hooks/calendar_canvas.js";

export const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  set_applied: "Showing the %{name} set",
  set_cleared: "Calendar set turned off",
  more: "more",
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
  range_on_day: "%{date}, %{start} to %{finish}",
  moving: "Moving %{title}, %{when}.",
  move_cancelled: "Move cancelled. %{title} stays at %{when}.",
  move_saving: "Saving %{title} at %{when}.",
  calendar_role: "calendar",
  period_range: "%{from} to %{to}",
  new_event: "New event",
  quick_create_label: "New event",
  quick_create_placeholder: "Title, or: lunch 13:00 /personal",
  quick_create_hint: "Enter saves, Esc cancels. Type a day and time, /calendar, @email or ;place.",
  save: "Save",
  save_and_invite: "Save and invite",
  more_options: "More options",
  show_as: "Show as",
  busy: "Busy",
  free: "Free",
  date_chip: "Date",
  start_chip: "Starts",
  end_chip: "Ends",
  time_to: "to",
  all_day_chip: "All day",
  calendar_chip: "Calendar",
  place_chip: "Place",
  guests_chip: "Guests",
  saving_draft: "Saving…",
  create_refused: "Couldn't save this event. Try again.",
  create_unconfirmed: "Couldn't confirm the save. Check your calendar.",
  dismiss: "Dismiss",
  kind_label: "What to add",
  kind_event: "Event",
  kind_open: "Open for booking",
  meeting_type_chip: "Meeting type",
  repeat_label: "Repeat",
  just_this_once: "Just this once",
  every_week: "Every week",
  open_save: "Open for booking",
  open_hint: "Guests can book this time on your booking page. The day's hours widen to include it.",
  open_draft_title: "Open for %{name}",
  open_refused: "Couldn't open that time. Please try again.",
  open_unconfirmed: "Couldn't confirm the change. Check your bookable times.",
  no_calendar_note: "Connect a calendar to add events, or use More options to send a Tymeslot meeting.",
  read_only_calendars_note: "Your calendars are read-only. Connect one you can write to, or use More options to send a Tymeslot meeting.",
  bookable: "Bookable",
  bookable_label: "%{date}: bookable times for %{meeting_type}. Show what this means",
  next_bookable: "Next bookable time: %{when}",
  show: "Show",
  bookable_error: "Couldn't load your bookable times.",
  bookable_title: "Bookable times",
  bookable_explainer: "Guests can book %{meeting_type} in the hatched times. Busy events, buffers and your notice period are already taken out, so this is exactly what your booking page offers.",
  bookable_hide_hint: "Press B to hide bookable times.",
  copy_free_times: "Copy free times",
  block_this_time: "Block this time",
  blocking: "Blocking…",
  block_refused: "Couldn't block that time. Please try again.",
  copied: "Free times for these days copied.",
  copy_failed: "Couldn't copy. Your browser blocked the clipboard.",
  free_times_day: "%{date}: %{times}",
  free_times_zone: "Times in %{zone}",
  free_times_none: "No bookable times on these days.",
  time_range: "%{start} to %{finish}",
  today: "Today",
  agenda_label: "Agenda",
  agenda_empty: "Nothing planned in these weeks.",
  agenda_until: "Until %{time}",
  agenda_from: "From %{time}",
  agenda_later: "Show later",
  agenda_loading: "Loading more",
  agenda_lens_label: "Filter agenda",
  agenda_lens_all: "All",
  agenda_lens_bookings: "Bookings",
  agenda_no_bookings: "No bookings in these weeks.",
  month_more: "More on %{date}: %{count}",
  month_attention: "includes something that needs your attention",
  month_select: "%{date}, show this day's events",
  day_events: "Events: %{count}",
  strip_label: "Days of this week",
};

// Writable calendars, as settings.calendars carries them.
export const calendars = [
  { key: "7:work", name: "Work", account: "anna@example.com", colour: "calendar-3" },
  { key: "7:personal", name: "Personal", account: "anna@example.com", colour: "calendar-5" },
];

// The power layer's keys (PowerSettings) at their defaults, as the server sends them before Tasks 4 to 11 fill them.
export const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: false, time_format: "24h", working_hours: {}, calendars, default_calendar: "7:work", show_week_numbers: false, sets: [], active_set: 0, focus: false, desktop_reminders: false };

export const event = (id, title, start, end, extra = {}) => ({
  id,
  kind: "event",
  title,
  all_day: false,
  start,
  end,
  colour: "calendar-2",
  free: false,
  attention: false,
  editable: true, movable: true,
  ...extra,
});

export function payload(overrides = {}) {
  return {
    view: "week",
    date: "2026-10-14",
    range: { from: "2026-10-05", to: "2026-10-26" },
    now: "2026-10-14T08:30",
    reset: true,
    settings,
    events: [
      event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00"),
      event("event-2", "Planning", "2026-10-14T14:00", "2026-10-14T15:00"),
      event("event-3", "Lunch", "2026-10-15T12:00", "2026-10-15T13:00"),
    ],
    ...overrides,
  };
}

const mounted = [];

export function mountHook(first = payload()) {
  const el = document.createElement("div");
  el.id = "calendar-canvas";
  el.dataset.view = "week";
  el.dataset.date = "2026-10-14";
  el.dataset.strings = JSON.stringify(strings);
  // jsdom has no layout; a real width keeps two events at one time side by side.
  Object.defineProperty(el, "clientWidth", { value: 900 });
  const live = document.createElement("div");
  live.id = "calendar-live";
  document.body.append(el, live);

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
  // The first push is calendar:ready; its params say whether a phone asked.
  const [, , readyParams, reply] = hook.pushEventTo.mock.calls[0];
  reply(first);
  hook.pushEventTo.mockClear();
  return { el, hook, handlers, live, readyParams };
}

let restoreViewport = null;

/**
 * Stubs window.matchMedia so the phone query answers `phone`. The returned
 * `set(next)` changes the answer and fires the change listeners, as a
 * rotation or a resized window would; `listeners` is the live set.
 * Call before mountHook. unmountAll puts the window back.
 */
export function mockViewport(phone) {
  const listeners = new Set();
  const media = {
    matches: phone,
    media: "(width < 40rem)",
    addEventListener: (_type, listener) => listeners.add(listener),
    removeEventListener: (_type, listener) => listeners.delete(listener),
  };
  const other = { matches: false, addEventListener() {}, removeEventListener() {} };
  const had = Object.prototype.hasOwnProperty.call(window, "matchMedia");
  const original = window.matchMedia;
  window.matchMedia = vi.fn((query) => (query === "(width < 40rem)" ? media : other));
  restoreViewport = () => {
    if (had) window.matchMedia = original;
    else delete window.matchMedia;
  };
  return {
    listeners,
    set(next) {
      media.matches = next;
      for (const listener of [...listeners]) listener({ matches: next, media: media.media });
    },
  };
}

export function unmountAll() {
  while (mounted.length) mounted.pop().destroyed();
  restoreViewport?.();
  restoreViewport = null;
  document.body.innerHTML = "";
}

export function pushes(hook, name) {
  return hook.pushEventTo.mock.calls.filter(([, pushed]) => pushed === name).map(([, , params]) => params);
}

export const block = (el, id) => el.querySelector(`.cal-col .cal-ev[data-event-id="${id}"]`);

// A touch pointer event as a phone sends it, dispatched on `target`. A finger
// holds the primary button (buttons 1) until it lifts or is cancelled; the
// first finger is the primary one. The pointer fields are pinned on the
// instance, so the event reads the same whichever constructor jsdom offers.
// Returns the event, so a test can read defaultPrevented.
export function touch(target, type, { x = 0, y = 0, pointerId = 1 } = {}) {
  const Constructor = typeof PointerEvent === "function" ? PointerEvent : MouseEvent;
  const e = new Constructor(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });
  const lifted = type === "pointerup" || type === "pointercancel";
  const fields = { pointerId, pointerType: "touch", isPrimary: pointerId === 1, buttons: lifted ? 0 : 1 };
  for (const [key, value] of Object.entries(fields)) Object.defineProperty(e, key, { value });
  target.dispatchEvent(e);
  return e;
}
