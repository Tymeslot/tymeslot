/**
 * Touch gesture maths for the calendar canvas: when a resting finger becomes
 * a long-press, and when it has moved too far to be one. Pure functions of
 * points; the hook does the DOM (see hooks/calendar_canvas/touch_drag.js).
 */

// How long a finger rests on an event before it picks the event up. Long
// enough that a scroll which happens to start on an event stays a scroll.
export const LONG_PRESS_MS = 400;
// Pixels a resting finger may wander before the press counts as a scroll.
export const PRESS_SLOP = 8;

export function movedBeyond(start, point, slop = PRESS_SLOP) {
  return Math.hypot(point.x - start.x, point.y - start.y) > slop;
}
