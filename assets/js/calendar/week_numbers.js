/**
 * ISO week numbers for the week-number cells (render.js, render_month.js).
 * Mirrors Period.week_number/1, so the canvas and the server's mini month
 * agree: a row is numbered by its Monday, else by its first day, which
 * numbers a Sunday-start row by the Monday after its Sunday.
 */
import { dayNumber, isoFromDay, isoWeekday } from "./time.js";

// The week holding the day's Thursday, counted from the week holding 1 January
// of the Thursday's year (ISO 8601).
export function isoWeek(iso) {
  const day = dayNumber(iso);
  const thursday = day + 4 - isoWeekday(day);
  const year = isoFromDay(thursday).slice(0, 4);
  return Math.floor((thursday - dayNumber(`${year}-01-01`)) / 7) + 1;
}

export function rowWeek(days) {
  const monday = days.find((iso) => isoWeekday(dayNumber(iso)) === 1);
  return isoWeek(monday ?? days[0]);
}
