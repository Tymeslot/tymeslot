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
  bookable: "Bookable",
  bookable_label: "%{date}: bookable times for %{meeting_type}. Show what this means",
  next_bookable: "Next bookable time: %{when}",
  show: "Show",
  bookable_error: "Couldn't load your bookable times.",
};

// Writable calendars, as settings.calendars carries them.
export const calendars = [
  { key: "7:work", name: "Work", account: "anna@example.com", colour: "calendar-3" },
  { key: "7:personal", name: "Personal", account: "anna@example.com", colour: "calendar-5" },
];

export const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: false, time_format: "24h", working_hours: {}, calendars, default_calendar: "7:work" };

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
  hook.pushEventTo.mock.calls[0][3](first);
  hook.pushEventTo.mockClear();
  return { el, hook, handlers, live };
}

export function unmountAll() {
  while (mounted.length) mounted.pop().destroyed();
  document.body.innerHTML = "";
}

export function pushes(hook, name) {
  return hook.pushEventTo.mock.calls.filter(([, pushed]) => pushed === name).map(([, , params]) => params);
}

export const block = (el, id) => el.querySelector(`.cal-col .cal-ev[data-event-id="${id}"]`);
