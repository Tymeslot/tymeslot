/**
 * Finding an event the command bar asked to reveal
 * (hooks/calendar_canvas/reveal.js) in what the canvas has drawn. Pure
 * apart from reading the DOM it is given.
 *
 * An event is found as itself (`[data-event-id]` outside an open list: a
 * time-grid block, an all-day bar, a month chip, a phone month's day list,
 * an agenda row) or as the "+N" control that hides it: a time-grid cluster
 * chip whose `data-hidden` names it, an all-day lane "+N" on a day it
 * covers, or a month day's "+N" on a day it falls on.
 */
import { eventsForDays } from "./cache.js";
import { NIGHT_END, dayNumber } from "./time.js";

const find = (root, selector, test) => [...root.querySelectorAll(selector)].find(test) ?? null;

function targetFor(root, id, cache) {
  const drawn = find(root, "[data-event-id]", (node) => node.dataset.eventId === id && !node.closest(".cal-list"));
  if (drawn) return { kind: "event", node: drawn, id };
  const chip = find(root, ".cal-more[data-hidden]", (node) => node.dataset.hidden.split(",").includes(id));
  if (chip) return { kind: "chip", node: chip, id };
  const event = cache.events.get(id);
  if (!event) return null;
  const allDay = event.long
    ? find(root, "[data-allday-more]", (node) => {
        const day = dayNumber(node.dataset.alldayMore);
        return event.startDay <= day && event.endDay > day;
      })
    : null;
  if (allDay) return { kind: "allday", node: allDay, id };
  const month = find(root, "[data-month-more]", (node) => eventsForDays(cache, [node.dataset.monthMore]).some((e) => e.id === id));
  return month ? { kind: "month", node: month, id } : null;
}

// The first of `ids` the canvas shows, as `{kind, node, id}`, or null.
export function revealTarget(root, ids, cache) {
  for (const id of ids) {
    const target = targetFor(root, id, cache);
    if (target) return target;
  }
  return null;
}

// Whether the folded early hours must open for a timed event at `startMin` (minute of the day).
export function needsNight(startMin, allDay, settings, nightOpen) {
  return !allDay && startMin != null && Boolean(settings?.fold_night) && !nightOpen && startMin < NIGHT_END;
}

// A search row's data attributes as `revealEvent`'s argument.
export function revealRequest(dataset) {
  return {
    ids: String(dataset.revealIds || "")
      .split(",")
      .filter(Boolean),
    date: dataset.date,
    startMin: dataset.startMin === undefined || dataset.startMin === "" ? null : Number(dataset.startMin),
    allDay: dataset.allDay === "true",
  };
}
