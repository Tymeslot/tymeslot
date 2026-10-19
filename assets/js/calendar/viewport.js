/**
 * The one width test the calendar's scripts make. Phone mode is below 40rem
 * (640px), Tailwind's `sm` boundary, the query calendar-phone.css uses. The
 * layout itself is chosen by CSS; scripts read this only to tell the server,
 * which picks the view, and to place overlays.
 */
export const PHONE_QUERY = "(width < 40rem)";

export function isPhone(win = typeof window === "undefined" ? undefined : window) {
  return typeof win?.matchMedia === "function" && win.matchMedia(PHONE_QUERY).matches === true;
}

// A finger, not a mouse, is the main pointer: quick create's native inputs
// take the tap, and (Task 13) tapping selects an event and shows its resize
// handle. Not a width test: a touch tablet in desktop chrome counts too.
export const COARSE_QUERY = "(pointer: coarse)";

export function isCoarse(win = typeof window === "undefined" ? undefined : window) {
  return typeof win?.matchMedia === "function" && win.matchMedia(COARSE_QUERY).matches === true;
}

// Event and all-day sizes for the time grid. A phone's are taller, so a short
// event or an all-day bar is a thumb-sized target.
const PHONE_METRICS = Object.freeze({ minEventHeight: 24, allDayRow: 32 });
const WIDE_METRICS = Object.freeze({ minEventHeight: 20, allDayRow: 22 });

export function metricsFor(phone) {
  return phone ? PHONE_METRICS : WIDE_METRICS;
}
