/**
 * The agenda's model: which days it can show and its events grouped by day.
 *
 * The agenda starts at its date and runs as far as the hook holds days in a
 * row (`agendaDays`), at most AGENDA_MAX_DAYS, so it never shows a gap; the
 * hook asks the server for more as its end scrolls into sight (see
 * hooks/calendar_canvas/views.js).
 *
 * Its lens shows everything ("all") or only what Tymeslot made ("bookings"):
 * the bookings, whose calendar copies are drawn as the bookings, and the
 * events created here (`tymeslot`), such as a meeting made with New event.
 */
import { AGENDA_MAX_DAYS, MINUTES_PER_DAY, dayNumber, isoFromDay } from "./time.js";

export function agendaDays(cache, date, maxDays = AGENDA_MAX_DAYS) {
  const days = [];
  for (let day = dayNumber(date); days.length < maxDays && cache.ranges.some(([from, to]) => from <= day && day < to); day += 1) {
    days.push(isoFromDay(day));
  }
  return days;
}

// Each day with something on it: all-day items first, then by start. An item
// covering the whole day reads as all-day; `from` and `to` are minutes from
// the day's midnight.
export function agendaGroups(events, days, { today }) {
  return days
    .map((day) => {
      const start = dayNumber(day) * MINUTES_PER_DAY;
      const end = start + MINUTES_PER_DAY;
      const items = events
        .filter((e) => e.kind !== "draft" && e.startMin < end && Math.max(e.endMin, e.startMin + 1) > start)
        .map((e) => {
          const from = Math.max(e.startMin, start) - start;
          const to = Math.min(e.endMin, end) - start;
          return { event: e, allDay: Boolean(e.all_day) || (from === 0 && to === MINUTES_PER_DAY), from, to, continuesBefore: e.startMin < start, continuesAfter: e.endMin > end };
        })
        .sort((a, b) => b.allDay - a.allDay || a.from - b.from || a.to - b.to || String(a.event.title).localeCompare(String(b.event.title)));
      return { day, today: day === today, items };
    })
    .filter((group) => group.items.length > 0);
}

export const AGENDA_LENSES = ["all", "bookings"];

// The events the lens shows.
export function lensEvents(events, lens) {
  return lens === "bookings" ? events.filter((e) => e.kind === "booking" || e.tymeslot === true) : events;
}
