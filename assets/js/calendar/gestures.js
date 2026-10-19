/**
 * Touch gesture maths for the calendar canvas: long-presses, swipes and pinches.
 * Pure functions of points and times; the hook does the DOM (see
 * hooks/calendar_canvas/touch_drag.js and gestures.js).
 */
import { MAX_HOUR, MIN_HOUR } from "./zoom.js";

// How long a finger rests on an event before it picks the event up. Long
// enough that a scroll which happens to start on an event stays a scroll.
export const LONG_PRESS_MS = 400;
// Pixels a resting finger may wander before the press counts as a scroll.
export const PRESS_SLOP = 8;

export function movedBeyond(start, point, slop = PRESS_SLOP) {
  return Math.hypot(point.x - start.x, point.y - start.y) > slop;
}

// A swipe changes the period when it travels SWIPE_MIN pixels sideways, at
// least SWIPE_RATIO times as far as it moved up or down, within SWIPE_MAX_MS.
export const SWIPE_MIN = 60;
export const SWIPE_RATIO = 1.5;
export const SWIPE_MAX_MS = 600;
// The furthest the drawn period follows a finger, as a share of its width.
const FOLLOW_SHARE = 0.4;

// The period a finger from `start` to `end` asks for: 1, the next (a swipe
// to the left), -1, the previous, or 0 when it was no swipe.
export function swipeStep(start, end, elapsedMs) {
  const dx = end.x - start.x;
  const dy = end.y - start.y;
  if (elapsedMs > SWIPE_MAX_MS || Math.abs(dx) < SWIPE_MIN || Math.abs(dx) < SWIPE_RATIO * Math.abs(dy)) return 0;
  return dx < 0 ? 1 : -1;
}

// How far the drawn period follows a finger `dx` pixels sideways: one for one
// at first, then less and less, never past FOLLOW_SHARE of `width`.
export function swipeOffset(dx, width) {
  const limit = Math.max(1, width) * FOLLOW_SHARE;
  return (dx * limit) / (Math.abs(dx) + limit);
}

export function pinchDistance(a, b) {
  return Math.hypot(b.x - a.x, b.y - a.y);
}

// The hour height a pinch leads to: the height it started at, scaled by how
// far the fingers have spread since, within the zoom's bounds.
export function pinchedHour(startHour, startDistance, distance) {
  const scaled = startDistance > 0 ? (startHour * distance) / startDistance : startHour;
  return Math.min(MAX_HOUR, Math.max(MIN_HOUR, scaled));
}
