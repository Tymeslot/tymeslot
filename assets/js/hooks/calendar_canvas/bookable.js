/**
 * The bookable-times layer, for the CalendarCanvas hook (mixed into it).
 *
 * B anywhere on the page but a text field, a dialog or an open quick
 * create turns the layer on or off, as the rail's switch does: the hook
 * pushes `calendar:bookable_toggle` and the server saves the choice.
 */
import { MODALS, TYPING } from "./keys.js";

export const BookableMixin = {
  mountBookable() {
    this.bookableKey = (e) => {
      if ((e.key !== "b" && e.key !== "B") || e.repeat || e.ctrlKey || e.metaKey || e.altKey || e.isComposing || e.defaultPrevented) return;
      if (this.drag || this.createDrag || this.moving || this.quick) return;
      const target = e.target;
      if (target?.isContentEditable || target?.closest?.(`${TYPING}, [role="dialog"], dialog`) || document.querySelector(MODALS)) return;
      e.preventDefault();
      this.toggleBookable();
    };
    document.addEventListener("keydown", this.bookableKey);
  },

  destroyBookable() {
    document.removeEventListener("keydown", this.bookableKey);
  },

  toggleBookable() {
    this.pushEventTo(this.el, "calendar:bookable_toggle", {});
  },
};
