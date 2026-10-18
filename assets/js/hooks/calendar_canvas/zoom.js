/**
 * Ctrl + scroll zoom for the CalendarCanvas hook (mixed into it). Ctrl with
 * the wheel, or a trackpad pinch (reported as a wheel with Ctrl), changes the
 * hour height (calendar/zoom.js) and keeps the minute under the pointer where
 * it was; Cmd does the same on macOS. The height is kept fractional in
 * `zoomHour` and rounded where it is drawn. Lasts for the visit; a density
 * change resets it.
 */
import { wheelPixels, zoomedHour } from "../../calendar/zoom.js";

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
    const cols = this.el.querySelector(".cal-cols");
    const scroller = this.el.querySelector("[data-scroll]");
    if (!cols) return;
    e.preventDefault();

    const delta = wheelPixels(e.deltaY, e.deltaMode, scroller?.clientHeight || 0);
    const before = this.hourHeight();
    const minute = this.currentScale().minuteOf(e.clientY - cols.getBoundingClientRect().top);
    this.zoomHour = zoomedHour(this.zoomHour ?? before, delta);
    if (this.hourHeight() === before) return;

    this.render();

    const nextScroller = this.el.querySelector("[data-scroll]");
    const nextCols = this.el.querySelector(".cal-cols");
    if (nextScroller && nextCols) {
      nextScroller.scrollTop += nextCols.getBoundingClientRect().top + this.currentScale().yOf(minute) - e.clientY;
      this.scrollTop = nextScroller.scrollTop;
    }
  },
};
