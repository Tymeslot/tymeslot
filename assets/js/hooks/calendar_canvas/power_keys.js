/**
 * The CalendarCanvas hook's power-layer keys (mixed into it): T goes to
 * today's period and J and K to the next and previous one, in the view on
 * screen (or the one asked for and not yet confirmed), through `gotoPeriod`
 * (views.js), so the grid draws at once from the cache and the server
 * follows. F toggles focus mode from 1024px wide. Later tasks add the set
 * digits and ? to `POWER_KEYS`.
 *
 * One document listener, so the keys work with focus anywhere on the page
 * but a text field, a dialog or a modal (`plainKeyAllowed`,
 * calendar/shortcuts.js). Letters and digits ignore Shift; ? is the only
 * key read with it. Ctrl K never reaches K: a modifier fails the guard.
 */
import { plainKeyAllowed } from "../../calendar/shortcuts.js";
import { MINUTES_PER_DAY, isoFromDay, shiftPeriod } from "../../calendar/time.js";

// Focus mode changes nothing below 1024px, where the dashboard menu is a drawer.
const WIDE = "(width >= 64rem)";

// Each action takes the hook and the key event.
export const POWER_KEYS = {
  t: (hook) => hook.gotoPeriod(hook.periodFrom().view, isoFromDay(Math.floor(hook.nowMinute() / MINUTES_PER_DAY))),
  j: (hook) => hook.stepPeriod(1),
  k: (hook) => hook.stepPeriod(-1),
  // Focus mode lives in the dashboard's layout, so the push goes to the LiveView, not the surface.
  f: (hook) => {
    if (!window.matchMedia?.(WIDE)?.matches) return;
    hook.pushEvent("calendar:toggle_focus", {});
  },
};

// The key's name in POWER_KEYS: a single character pressed without Shift, lower-cased, or "?".
export function powerKeyName(e) {
  if (e.key === "?") return "?";
  if (e.shiftKey || typeof e.key !== "string" || e.key.length !== 1) return null;
  return e.key.toLowerCase();
}

export const PowerKeysMixin = {
  mountPowerKeys() {
    this.powerKeyListener = (e) => this.powerKey(e);
    document.addEventListener("keydown", this.powerKeyListener);
  },

  destroyPowerKeys() {
    document.removeEventListener("keydown", this.powerKeyListener);
  },

  powerKey(e) {
    const action = POWER_KEYS[powerKeyName(e)];
    if (!action || !plainKeyAllowed(e, this)) return;
    e.preventDefault();
    action(this, e);
  },

  // Where a step starts: the period asked for and not yet confirmed, else the one on screen.
  periodFrom() {
    return this.pending ?? { view: this.view, date: this.date };
  },

  stepPeriod(direction) {
    const { view, date } = this.periodFrom();
    this.gotoPeriod(view, shiftPeriod(view, date, direction));
  },
};
