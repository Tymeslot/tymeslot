/**
 * Ctrl + scroll zoom for the CalendarCanvas hook (mixed into it). Ctrl with
 * the wheel, or a trackpad pinch (reported as a wheel with Ctrl), changes the
 * hour height (calendar/zoom.js) and keeps the minute under the pointer where
 * it was; Cmd does the same on macOS. The height is kept fractional in
 * `zoomHour` and rounded where it is drawn. Lasts for the visit; a density
 * change resets it. A pinch on a touch screen zooms through the same zoomTo (see
 * gestures.js).
 */
import { MAX_HOUR, MIN_HOUR, wheelPixels, zoomedHour } from "../../calendar/zoom.js";

const onMac = () => /mac/i.test(globalThis.navigator?.platform || "");

export const ZoomMixin = {
  mountZoom() {
    this.zoomHour = null;
    this.wheel = (e) => this.zoom(e);
    // Not passive: zooming must stop the browser's own page zoom. Only a zoom
    // calls preventDefault, so ordinary scrolling is unaffected.
    this.el.addEventListener("wheel", this.wheel, { passive: false });
  },

  destroyZoom() {
    this.el.removeEventListener("wheel", this.wheel);
  },

  zoom(e) {
    if (!(e.ctrlKey || (e.metaKey && onMac())) || !this.settings) return;
    // A live drag keeps its scale, and the browser must not zoom the page under it either.
    if (this.drag) {
      e.preventDefault();
      return;
    }
    if (!this.el.querySelector(".cal-cols")) return;
    e.preventDefault();

    const scroller = this.el.querySelector("[data-scroll]");
    const delta = wheelPixels(e.deltaY, e.deltaMode, scroller?.clientHeight || 0);
    this.zoomTo(zoomedHour(this.zoomHour ?? this.hourHeight(), delta), e.clientY);
  },

  // Draws the hours `hourHeight` high (kept fractional, within MIN_HOUR and
  // MAX_HOUR) and keeps the minute at `clientY` where it was. The wheel and
  // a pinch (gestures.js) both land here. True when the drawn height changed.
  zoomTo(hourHeight, clientY) {
    const cols = this.el.querySelector(".cal-cols");
    if (!cols || !this.settings || this.drag) return false;
    const before = this.hourHeight();
    const minute = this.currentScale().minuteOf(clientY - cols.getBoundingClientRect().top);
    this.zoomHour = Math.min(MAX_HOUR, Math.max(MIN_HOUR, hourHeight));
    if (this.hourHeight() === before) return false;

    this.render();

    const nextScroller = this.el.querySelector("[data-scroll]");
    const nextCols = this.el.querySelector(".cal-cols");
    if (nextScroller && nextCols) {
      nextScroller.scrollTop += nextCols.getBoundingClientRect().top + this.currentScale().yOf(minute) - clientY;
      this.scrollTop = nextScroller.scrollTop;
    }
    return true;
  },
};
