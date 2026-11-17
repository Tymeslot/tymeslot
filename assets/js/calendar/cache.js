/**
 * The canvas's copy of the events the server has sent, and which days they
 * cover. Each payload covers the visible period plus one period either side
 * and replaces every cached event overlapping that range, so the server stays
 * the only source of truth; `reset` (sent after a visibility change or on a
 * fresh mount) drops everything first.
 */
import { dayNumber, normaliseEvent } from "./time.js";

export function emptyCache() {
  return { events: new Map(), ranges: [] };
}

export function applyPayload(cache, payload) {
  const from = dayNumber(payload.range.from);
  const to = dayNumber(payload.range.to);
  const base = payload.reset ? emptyCache() : cache;
  const events = new Map();

  for (const [id, event] of base.events) {
    if (!(event.startDay < to && event.endDay > from)) events.set(id, event);
  }
  for (const raw of payload.events) {
    const event = normaliseEvent(raw);
    events.set(event.id, event);
  }

  return { events, ranges: mergeRanges([...base.ranges, [from, to]]) };
}

export function isLoaded(cache, days) {
  return days.every((iso) => {
    const day = dayNumber(iso);
    return cache.ranges.some(([from, to]) => from <= day && day < to);
  });
}

export function eventsForDays(cache, days) {
  if (!days.length) return [];
  const from = dayNumber(days[0]);
  const to = dayNumber(days[days.length - 1]) + 1;
  return [...cache.events.values()].filter((e) => e.startDay < to && e.endDay > from);
}

function mergeRanges(ranges) {
  const sorted = [...ranges].sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const [from, to] of sorted) {
    const last = merged[merged.length - 1];
    if (last && from <= last[1]) last[1] = Math.max(last[1], to);
    else merged.push([from, to]);
  }
  return merged;
}
