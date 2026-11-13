/**
 * ViewportMixin for the CalendarCanvas hook: whether the canvas is on a
 * phone (below 40rem, PHONE_QUERY), which the server needs to choose the
 * view (a week shows as three days there).
 *
 * The layout never depends on this: CSS shows the phone or the desktop
 * chrome. The hook reads `this.phone` for what only it does: the first
 * request (`calendar:ready` carries `phone`), a week asked for on a phone
 * (drawn as three days at once, as the server will answer), and the
 * overlays' placement (`sheetMode()`). A width that crosses the boundary (a
 * rotation, a resized window) is reported as `calendar:viewport` once it
 * has settled; the server answers with the period it now shows.
 */
import { keyboardInset } from "../../calendar/sheet.js";
import { PHONE_QUERY } from "../../calendar/viewport.js";

export const VIEWPORT_DEBOUNCE_MS = 150;

export const ViewportMixin = {
  mountViewport() {
    this.media = typeof window.matchMedia === "function" ? window.matchMedia(PHONE_QUERY) : null;
    this.phone = this.media?.matches === true;
    this.viewportTimer = null;
    this.viewportListener = () => {
      clearTimeout(this.viewportTimer);
      this.viewportTimer = setTimeout(() => this.viewportChanged(), VIEWPORT_DEBOUNCE_MS);
    };
    this.media?.addEventListener?.("change", this.viewportListener);
    this.mountKeyboardInset();
  },

  destroyViewport() {
    this.destroyKeyboardInset();
    clearTimeout(this.viewportTimer);
    this.viewportTimer = null;
    this.media?.removeEventListener?.("change", this.viewportListener);
    this.media = null;
  },

  viewportChanged() {
    this.viewportTimer = null;
    const phone = this.media?.matches === true;
    if (phone === this.phone) return;
    this.phone = phone;
    // A sheet keeps its placement until it closes (decision 11), but not
    // across a flip: nothing may keep `.is-sheet` on a wide screen.
    this.closeList();
    this.closeExplainer();
    this.placeQuickCreate();
    this.pushEventTo(this.el, "calendar:viewport", { phone });
    // The cache holds the three days; the server's answer confirms them.
    if (phone && this.view === "week" && !this.pending) {
      this.view = "three_day";
      this.render();
    }
  },

  // iOS leaves position: fixed elements behind the on-screen keyboard. The
  // part of the layout viewport the keyboard covers goes to --cal-kb-inset,
  // which lifts the sheets and the full-screen editor (calendar-phone.css);
  // quick create's draft is then kept clear of the risen sheet.
  mountKeyboardInset() {
    const visual = window.visualViewport;
    if (!visual) return;
    this.insetListener = () => {
      document.documentElement.style.setProperty("--cal-kb-inset", `${keyboardInset(window.innerHeight, visual)}px`);
      if (this.quick) this.revealDraft();
    };
    visual.addEventListener("resize", this.insetListener);
    visual.addEventListener("scroll", this.insetListener);
    this.insetListener();
  },

  destroyKeyboardInset() {
    const visual = window.visualViewport;
    if (visual && this.insetListener) {
      visual.removeEventListener("resize", this.insetListener);
      visual.removeEventListener("scroll", this.insetListener);
    }
    this.insetListener = null;
    document.documentElement.style.removeProperty("--cal-kb-inset");
  },

  // Overlays open as bottom sheets on a phone (see calendar/sheet.js).
  sheetMode() {
    return this.phone === true;
  },

  // The view a navigation lands on: a week is three days on a phone.
  viewFor(view) {
    return this.phone && view === "week" ? "three_day" : view;
  },
};
