/**
 * The bookable-times layer, for the CalendarCanvas hook (mixed into it).
 *
 * The server pushes the layer as `calendar:bookable` (see
 * TymeslotWeb.Dashboard.Calendar.BookableLayer): whether it is on, the
 * meeting type it is for, its windows as wall-clock times, the next
 * bookable time and whether loading failed. The hook keeps the last one in
 * `this.bookable` and the grid draws it behind the events
 * (calendar/render.js, calendar/bookable.js). The reply to `calendar:ready`
 * carries it too, so a hook mounted after the push still has it.
 *
 * B anywhere on the page but a text field, a dialog or an open quick
 * create turns the layer on or off, as the rail's switch does: the grid
 * follows at once and the hook pushes `calendar:bookable_toggle` for the
 * server to save it. The note's Show goes to the next bookable time's
 * period, in the same view, and scrolls to an hour before it.
 */
import { MINUTES_PER_DAY, parseWall } from "../../calendar/time.js";
import { MODALS, TYPING } from "./keys.js";

export const BookableMixin = {
  mountBookable() {
    this.bookable = null;
    this.scrollTarget = null;
    this.scrollDate = null;
    this.bookableKey = (e) => {
      if ((e.key !== "b" && e.key !== "B") || e.repeat || e.ctrlKey || e.metaKey || e.altKey || e.isComposing || e.defaultPrevented) return;
      if (this.drag || this.createDrag || this.moving || this.quick) return;
      const target = e.target;
      if (target?.isContentEditable || target?.closest?.(`${TYPING}, [role="dialog"], dialog`) || document.querySelector(MODALS)) return;
      e.preventDefault();
      this.toggleBookable();
    };
    document.addEventListener("keydown", this.bookableKey);
    this.handleEvent("calendar:bookable", (layer) => this.receiveBookable(layer));
  },

  destroyBookable() {
    document.removeEventListener("keydown", this.bookableKey);
  },

  // Whether a popover over the grid holds redraws back until it closes.
  overlayOpen() {
    return !!this.list;
  },

  receiveBookable(layer) {
    this.bookable = layer;
    if (this.overlayOpen()) {
      this.dirty = true;
      return;
    }
    this.render();
  },

  toggleBookable() {
    if (this.bookable) {
      this.bookable = { ...this.bookable, on: !this.bookable.on };
      this.render();
    }
    this.pushEventTo(this.el, "calendar:bookable_toggle", {});
  },

  showBookable(at) {
    const date = at.slice(0, 10);
    this.scrollTarget = parseWall(at) % MINUTES_PER_DAY;
    this.scrollDate = date;
    this.scrollTop = null;
    this.navigate({ view: this.view, date });
    this.pushEventTo(this.el, "calendar:goto", { view: this.view, date });
  },
};
