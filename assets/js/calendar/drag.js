/**
 * Drag maths for the calendar canvas: which slot a pointer is over, and the
 * snapped range a move or a resize shows while the pointer moves. Pure
 * functions of minutes and pixels; the hook does the DOM (see
 * hooks/calendar_canvas/drag.js).
 *
 * A move keeps the offset at which the event was grabbed, follows the
 * pointer across day columns and snaps the new start to SNAP minutes. A
 * resize moves one edge ("start" or "end") within the event's own day and
 * snaps it. Either way the range stays inside one day, never starts before
 * `firstMinute` (the end of the folded night) and is at least MIN_LENGTH
 * long.
 */
import { MINUTES_PER_DAY, dayNumber } from "./time.js";

export const SNAP = 15;
export const MIN_LENGTH = 15;
// Pixels a pressed pointer travels before a press becomes a drag.
export const DRAG_THRESHOLD = 4;

export function snap(minute, step = SNAP) {
  return Math.round(minute / step) * step;
}

// Whether the organiser can drag `event` (a normalised payload event): one
// they can move (`movable`, which is narrower than `editable`: the calendar
// copy of a booking can be deleted but not moved), timed, with a length, and
// inside one day. All-day bars and events that cross midnight still open and
// delete; they do not drag.
export function draggable(event) {
  return !!event.movable && !event.long && event.endMin > event.startMin && event.endDay - event.startDay === 1;
}

// The day column and minute under a pointer. `geometry` is the columns'
// left and top edge in client pixels, one column's width, the visible days
// and the vertical scale.
export function slotAt({ x, y }, { left, top, colWidth, days, scale }) {
  const index = Math.min(days.length - 1, Math.max(0, Math.floor((x - left) / colWidth)));
  return { index, day: dayNumber(days[index]), minute: scale.minuteOf(y - top) };
}

// What a drag remembers from the press that started it.
export function beginDrag(mode, event, slot) {
  return { mode, id: event.id, startMin: event.startMin, endMin: event.endMin, originDay: slot.day, originMinute: slot.minute };
}

export function dragRange(state, slot, firstMinute = 0) {
  const eventDay = Math.floor(state.startMin / MINUTES_PER_DAY);
  const base = eventDay * MINUTES_PER_DAY;

  if (state.mode === "move") {
    const length = state.endMin - state.startMin;
    const dayBase = (eventDay + slot.day - state.originDay) * MINUTES_PER_DAY;
    const wanted = snap(state.startMin - base + slot.minute - state.originMinute);
    const start = Math.max(0, Math.min(MINUTES_PER_DAY - length, Math.max(firstMinute, wanted)));
    return { startMin: dayBase + start, endMin: dayBase + start + length };
  }

  const minute = snap(slot.minute);

  if (state.mode === "end") {
    const end = Math.max(Math.min(state.startMin - base + MIN_LENGTH, MINUTES_PER_DAY), Math.min(MINUTES_PER_DAY, minute));
    return { startMin: state.startMin, endMin: base + end };
  }

  const start = Math.max(0, Math.min(state.endMin - base - MIN_LENGTH, Math.max(firstMinute, minute)));
  return { startMin: base + start, endMin: state.endMin };
}

// Where `range` is drawn in its day's column, at least 12px tall so a
// short range can still be seen.
export function previewBox(range, scale) {
  const base = Math.floor(range.startMin / MINUTES_PER_DAY) * MINUTES_PER_DAY;
  const top = scale.yOf(Math.max(range.startMin - base, scale.firstMinute));
  const bottom = scale.yOf(Math.min(range.endMin - base, MINUTES_PER_DAY));
  return { top, height: Math.max(bottom - top, 12) };
}
