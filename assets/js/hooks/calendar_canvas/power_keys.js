/**
 * The CalendarCanvas hook's power-layer keys (mixed into it): T goes to
 * today's period and J and K to the next and previous one, in the view on
 * screen (or the one asked for and not yet confirmed), through `gotoPeriod`
 * (views.js), so the grid draws at once from the cache and the server
 * follows. F toggles focus mode from 1024px wide. 0 to 9 apply calendar sets
 * (0 leaves the active one). ? opens the keyboard shortcuts.
 *
 * One document listener, so the keys work with focus anywhere on the page
 * but a text field, a dialog or a modal (`plainKeyAllowed`,
 * calendar/shortcuts.js). Letters and digits ignore Shift; ? is the only
 * key read with it. Ctrl K never reaches K: a modifier fails the guard.
 */
import { interpolate } from "../../calendar/render.js";
import { digitOf, plainKeyAllowed } from "../../calendar/shortcuts.js";
import { MINUTES_PER_DAY, isoFromDay, shiftPeriod } from "../../calendar/time.js";

// Focus mode changes nothing below 1024px, where the dashboard menu is a drawer.
export const WIDE = "(width >= 64rem)";

// 0 leaves the active set; 1 to 9 apply theirs. A digit with no set, or the
// active set's own, does nothing. The live region says what changed, since
// the chip changing is silent to a screen reader.
const setKey = (position) => (hook) => {
  const { sets = [], active_set: active = 0 } = hook.settings;
  if (position === active) return;
  const set = position === 0 ? null : sets.find((s) => s.position === position);
  if (position !== 0 && !set) return;
  hook.pushEventTo(hook.el, "calendar:apply_set", { position });
  hook.announce(set ? interpolate(hook.strings.set_applied, { name: set.name }) : hook.strings.set_cleared);
};

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
  // The help is a core modal on the surface; while it is open MODALS silences every key, this one included.
  "?": (hook) => hook.pushEventTo(hook.el, "calendar:toggle_menu", { menu: "shortcuts" }),
  ...Object.fromEntries(Array.from({ length: 10 }, (_, n) => [String(n), setKey(n)])),
};

/**
 * The table key `e` stands for: "?" (Shift allowed, it is how "?" is
 * typed), a digit from the number row or the numpad (Shift allowed, AZERTY types them with it), or a
 * letter in lower case without Shift. Anything else: null.
 */
export function powerKeyName(e) {
  if (e.key === "?") return "?";
  const digit = digitOf(e);
  if (digit !== null) return String(digit);
  if (e.shiftKey) return null;
  return typeof e.key === "string" && /^[a-z]$/i.test(e.key) ? e.key.toLowerCase() : null;
}

export const PowerKeysMixin = {
  mountPowerKeys() {
    this.powerKeyListener = (e) => this.powerKey(e);
    document.addEventListener("keydown", this.powerKeyListener);
    // The server hands focus back to a control whose editor closed: the first of `ids` on screen.
    this.handleEvent("calendar:focus", ({ ids = [] }) => {
      const target = ids.map((id) => document.getElementById(id)).find((el) => el && el.getClientRects().length > 0);
      target?.focus();
    });
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
