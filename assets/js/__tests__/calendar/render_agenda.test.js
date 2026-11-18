/**
 * Tests for the agenda list's HTML (calendar/render_agenda.js), run against jsdom.
 */
import { expect, test } from "vitest";
import { agendaGroups, lensEvents } from "../../calendar/agenda.js";
import { renderAgenda, renderAgendaDay } from "../../calendar/render_agenda.js";
import { normaliseEvent, parseWall } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  today: "Today",
  ended: "ended",
  shown_as_free: "shown as free",
  waiting_to_sync: "waiting to sync",
  request: "Request",
  request_expired: "Expired",
  request_aria: "request waiting for your answer",
  request_expired_aria: "request expired without an answer",
  empty_day: "Nothing planned on this day.",
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
};
const ev = (id, title, start, end, extra = {}) => normaliseEvent({ id, kind: "event", title, all_day: false, start, end, colour: "calendar-2", free: false, attention: false, ...extra });
const days = ["2026-10-14", "2026-10-15", "2026-10-16", "2026-10-17"];
const events = [
  ev("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00"),
  ev("event-2", "Bank holiday", "2026-10-14", "2026-10-15", { all_day: true }),
  ev("event-3", "Trip", "2026-10-15T22:00", "2026-10-17T10:00"),
  ev("booking-4", "Anna Kowalski · Intro call", "2026-10-16T09:00", "2026-10-16T09:30", { kind: "booking", request: true }),
  ev("event-5", "<b>Bold</b>", "2026-10-17T15:00", "2026-10-17T16:00", { free: true }),
];
const now = parseWall("2026-10-14T11:30");
const draw = (opts = {}) => {
  const holder = document.createElement("div");
  holder.innerHTML = renderAgenda({ groups: agendaGroups(events, days, { today: "2026-10-14" }), strings, timeFormat: "24h", now, done: false, ...opts });
  return holder;
};
const timeOf = (holder, id) => holder.querySelector(`[data-event-id="${id}"] .cal-agenda-time`).textContent;

test("each day with events gets a heading, today marked", () => {
  const holder = draw();
  expect([...holder.querySelectorAll("[data-agenda-day]")].map((d) => d.dataset.agendaDay)).toEqual(days);
  const today = holder.querySelector('[data-agenda-day="2026-10-14"] [aria-current="date"]');
  expect(today.textContent).toContain("Today");
  expect(holder.querySelector('[data-agenda-day="2026-10-15"] [aria-current]')).toBeNull();
});

test("rows are buttons that open the event, all-day first", () => {
  const holder = draw();
  const rows = [...holder.querySelectorAll('[data-agenda-day="2026-10-14"] button[data-event-id]')];
  expect(rows.map((r) => r.dataset.eventId)).toEqual(["event-2", "event-1"]);
});

test("times say all day, a range, or where a long event starts and ends", () => {
  const holder = draw();
  expect(timeOf(holder, "event-2")).toBe("All day");
  expect(timeOf(holder, "event-1")).toBe("11:00–12:00");
  expect(holder.querySelector('[data-agenda-day="2026-10-15"] .cal-agenda-time').textContent).toBe("From 22:00");
  expect(holder.querySelector('[data-agenda-day="2026-10-16"] [data-event-id="event-3"] .cal-agenda-time').textContent).toBe("All day");
  expect(holder.querySelector('[data-agenda-day="2026-10-17"] [data-event-id="event-3"] .cal-agenda-time').textContent).toBe("Until 10:00");
});

test("rows carry the request flag, the free outline and an accessible name", () => {
  const holder = draw();
  const request = holder.querySelector('[data-event-id="booking-4"]');
  expect(request.classList.contains("is-request")).toBe(true);
  expect(request.querySelector(".cal-agenda-flag").textContent).toBe("Request");
  expect(request.getAttribute("aria-label")).toBe("Anna Kowalski · Intro call, request waiting for your answer, Fri 16 Oct, 09:00–09:30");
  expect(holder.querySelector('[data-event-id="event-5"]').classList.contains("is-free")).toBe(true);
  expect(holder.querySelector('[data-event-id="event-5"]').getAttribute("aria-label")).toContain("shown as free");
});

test("an event that has ended says so", () => {
  const holder = draw({ now: parseWall("2026-10-14T12:30") });
  expect(holder.querySelector('[data-event-id="event-1"]').classList.contains("is-past")).toBe(true);
  expect(holder.querySelector('[data-event-id="event-1"]').getAttribute("aria-label")).toContain("ended");
});

test("titles are escaped", () => {
  const holder = draw();
  expect(holder.querySelector("b")).toBeNull();
  expect(holder.querySelector('[data-event-id="event-5"] .cal-agenda-title').textContent).toBe("<b>Bold</b>");
});

test("until it is done the list ends in the sentinel; then in Show later", () => {
  const open = draw();
  expect(open.querySelector("[data-agenda-sentinel]").textContent).toBe("Loading more");
  expect(open.querySelector("[data-agenda-later]")).toBeNull();

  const done = draw({ done: true });
  expect(done.querySelector("[data-agenda-sentinel]")).toBeNull();
  expect(done.querySelector("button[data-agenda-later]").textContent).toBe("Show later");
});

test("no events in the loaded weeks says so, and still asks for more", () => {
  const holder = document.createElement("div");
  holder.innerHTML = renderAgenda({ groups: [], strings, timeFormat: "24h", now, done: false });
  expect(holder.querySelector('[role="note"]').textContent).toBe("Nothing planned in these weeks.");
  expect(holder.querySelector("[data-agenda-sentinel]")).not.toBeNull();
});

test("the list is the view's own scroller and says when it is busy", () => {
  expect(draw().querySelector(".cal-agenda[data-view-scroll]").getAttribute("aria-busy")).toBeNull();
  expect(draw({ loading: true }).querySelector(".cal-agenda").getAttribute("aria-busy")).toBe("true");
});

test("renderAgendaDay draws one day, or the empty-day note", () => {
  const [group] = agendaGroups(events, ["2026-10-14"], { today: "2026-10-14" });
  const holder = document.createElement("ol");
  holder.innerHTML = renderAgendaDay(group, { strings, timeFormat: "24h", now });
  expect(holder.querySelectorAll("button[data-event-id]")).toHaveLength(2);
  expect(renderAgendaDay(null, { strings, timeFormat: "24h", now })).toContain("Nothing planned on this day.");
});

test("the lens heads the list, the one shown pressed", () => {
  const holder = draw();
  const lens = holder.querySelector('.cal-agenda-lens[role="group"]');
  expect(lens.getAttribute("aria-label")).toBe("Filter agenda");
  expect([...lens.querySelectorAll("button")].map((b) => [b.dataset.agendaLens, b.textContent, b.getAttribute("aria-pressed")])).toEqual([
    ["all", "All", "true"],
    ["bookings", "Bookings", "false"],
  ]);
  expect(draw({ lens: "bookings" }).querySelector('[data-agenda-lens="bookings"]').getAttribute("aria-pressed")).toBe("true");
});

test("the bookings lens keeps only bookings, and says so when there are none", () => {
  expect(lensEvents(events, "bookings").map((e) => e.id)).toEqual(["booking-4"]);
  expect(lensEvents(events, "all")).toEqual(events);

  const holder = draw({ groups: agendaGroups(lensEvents(events.slice(0, 3), "bookings"), days, { today: "2026-10-14" }), lens: "bookings" });
  expect(holder.querySelector(".cal-agenda-empty").textContent).toBe("No bookings in these weeks.");
  expect(draw({ groups: [] }).querySelector(".cal-agenda-empty").textContent).toBe("Nothing planned in these weeks.");
});

test("the bookings lens keeps the events made in Tymeslot too", () => {
  const made = ev("event-8", "Intro call", "2026-10-15T10:00", "2026-10-15T10:30", { tymeslot: true });
  const synced = ev("event-9", "Lunch", "2026-10-15T12:00", "2026-10-15T13:00", { tymeslot: false });
  expect(lensEvents([...events, made, synced], "bookings").map((e) => e.id)).toEqual(["booking-4", "event-8"]);
});
