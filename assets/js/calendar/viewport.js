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
