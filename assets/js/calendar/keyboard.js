/**
 * The calendar canvas's keyboard model, as pure functions.
 *
 * Focus (WAI-ARIA grid pattern: the grid is one tab stop and the arrow keys
 * move within it; they never change data): `items` are the event blocks as
 * drawn, `{id, day, minute, order}`, where `day` is a day number, `minute`
 * where the block starts that day and `order` its place in the document.
 * An event drawn on two days appears once per day, so a position is
 * `{id, day}`.
 *
 * Move mode (M on a focused event): Up and Down shift the event by STEP
 * minutes, Left and Right by a day, Shift with Up or Down changes its
 * length. The range comes from the drag maths (`dragRange`), so it stays
 * inside its day, after `firstMinute` and at least MIN_LENGTH long; Left
 * and Right stop at the visible days `firstDay`..`lastDay`.
 */
import { MIN_LENGTH, SNAP, dragRange } from "./drag.js";
import { MINUTES_PER_DAY } from "./time.js";

export const STEP = SNAP;

const byTime = (a, b) => a.minute - b.minute || a.order - b.order;

export function nextFocus(items, current, key) {
  const here = items.find((item) => item.id === current.id && item.day === current.day);
  if (!here) return null;

  if (key === "ArrowUp" || key === "ArrowDown" || key === "Home" || key === "End") {
    const day = items.filter((item) => item.day === here.day).sort(byTime);
    const index = day.indexOf(here);
    const target = { ArrowUp: day[index - 1], ArrowDown: day[index + 1], Home: day[0], End: day[day.length - 1] }[key];
    return target && target !== here ? { id: target.id, day: target.day } : null;
  }

  if (key === "ArrowLeft" || key === "ArrowRight") {
    const direction = key === "ArrowRight" ? 1 : -1;
    const days = [...new Set(items.map((item) => item.day))].filter((day) => (day - here.day) * direction > 0).sort((a, b) => (a - b) * direction);
    if (!days.length) return null;
    const nearest = items
      .filter((item) => item.day === days[0])
      .reduce((best, item) => (Math.abs(item.minute - here.minute) < Math.abs(best.minute - here.minute) ? item : best));
    return { id: nearest.id, day: nearest.day };
  }

  return null;
}

export function beginMove(event) {
  const range = { startMin: event.startMin, endMin: event.endMin };
  return { id: event.id, range, original: range };
}

export function moveStep(range, key, { shift, firstMinute, firstDay, lastDay }) {
  const day = Math.floor(range.startMin / MINUTES_PER_DAY);
  const base = day * MINUTES_PER_DAY;
  const vertical = key === "ArrowUp" ? -STEP : key === "ArrowDown" ? STEP : 0;
  const state = { mode: shift ? "end" : "move", startMin: range.startMin, endMin: range.endMin, originDay: day, originMinute: range.startMin - base };

  if (vertical) {
    const minute = (shift ? range.endMin : range.startMin) - base + vertical;
    return dragRange(state, { day, minute }, firstMinute);
  }

  const by = key === "ArrowLeft" ? -1 : key === "ArrowRight" ? 1 : 0;
  if (!by || shift || day + by < firstDay || day + by > lastDay) return range;
  return dragRange({ ...state, mode: "move" }, { day: day + by, minute: range.startMin - base }, firstMinute);
}
