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
 *
 * A day's label opens the explainer beside it (calendar/bookable_explainer.js):
 * "Copy free times" writes the visible days' windows to the clipboard
 * (calendar/free_times.js) and "Block this time" pushes `calendar:block`
 * with the labelled window, closing once the server accepts it. The
 * explainer lives in the canvas like the "+N" list, so redraws wait for it
 * to close (`overlayOpen`); Escape, a press outside or its label again
 * close it.
 */
import { formatFreeTimes } from "../../calendar/free_times.js";
import { renderExplainer } from "../../calendar/bookable_explainer.js";
import { placePopover } from "../../calendar/popover.js";
import { MINUTES_PER_DAY, parseWall, periodDays } from "../../calendar/time.js";
import { MODALS, TYPING } from "./keys.js";

const EXPLAINER_ESTIMATE = { width: 320, height: 220 };
const viewport = () => ({ width: window.innerWidth, height: window.innerHeight });

export const BookableMixin = {
  mountBookable() {
    this.bookable = null;
    this.scrollTarget = null;
    this.explainer = null;
    this.explainerDay = null;
    this.bookableKey = (e) => {
      if ((e.key !== "b" && e.key !== "B") || e.repeat || e.ctrlKey || e.metaKey || e.altKey || e.isComposing || e.defaultPrevented) return;
      if (this.drag || this.createDrag || this.moving || this.quick) return;
      const target = e.target;
      if (target?.isContentEditable || target?.closest?.(`${TYPING}, [role="dialog"], dialog`) || document.querySelector(MODALS)) return;
      e.preventDefault();
      this.toggleBookable();
    };
    // A press on a label is left to its click, which toggles the explainer.
    this.explainerOutside = (e) => {
      if (this.explainer && !this.explainer.contains(e.target) && !e.target.closest?.("[data-bookable-label]")) this.closeExplainer();
    };
    document.addEventListener("keydown", this.bookableKey);
    this.handleEvent("calendar:bookable", (layer) => this.receiveBookable(layer));
  },

  destroyBookable() {
    document.removeEventListener("keydown", this.bookableKey);
    document.removeEventListener("pointerdown", this.explainerOutside);
  },

  // Whether a popover over the grid holds redraws back until it closes.
  overlayOpen() {
    return !!(this.list || this.explainer);
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
    this.scrollTop = null;
    this.navigate({ view: this.view, date });
    this.pushEventTo(this.el, "calendar:goto", { view: this.view, date });
  },

  openExplainer(anchor) {
    const day = anchor.dataset.bookableLabel;
    const reopening = this.explainer && this.explainerDay === day;
    this.closeList();
    this.closeExplainer();
    if (reopening || !this.bookable?.meeting_type) return;

    const holder = document.createElement("div");
    holder.innerHTML = renderExplainer({
      day,
      start: anchor.dataset.start,
      end: anchor.dataset.end,
      meetingType: this.bookable.meeting_type.name,
      strings: this.strings,
      timeFormat: this.settings.time_format,
    });
    const explainer = holder.firstElementChild;
    this.el.appendChild(explainer);

    const size = { width: explainer.offsetWidth || EXPLAINER_ESTIMATE.width, height: explainer.offsetHeight || EXPLAINER_ESTIMATE.height };
    const position = placePopover(anchor.getBoundingClientRect(), size, viewport());
    explainer.style.left = `${Math.round(position.left)}px`;
    explainer.style.top = `${Math.round(position.top)}px`;
    explainer.style.maxHeight = position.maxHeight ? `${Math.round(position.maxHeight)}px` : "";
    this.explainer = explainer;
    this.explainerDay = day;
    document.addEventListener("pointerdown", this.explainerOutside);
    explainer.querySelector("button")?.focus();
  },

  // Forget the explainer without touching focus (a redraw has removed it).
  dropExplainer() {
    document.removeEventListener("pointerdown", this.explainerOutside);
    this.explainer = null;
    this.explainerDay = null;
    this.dirty = false;
  },

  closeExplainer() {
    if (!this.explainer) return;
    const hadFocus = this.explainer.contains(document.activeElement);
    const day = this.explainerDay;
    const stale = this.dirty;
    this.explainer.remove();
    this.dropExplainer();
    if (stale) this.render();
    if (hadFocus) this.focusBy({ attr: "data-bookable-label", value: day });
  },

  explainerStatus(text) {
    const status = this.explainer?.querySelector("[data-bookable-status]");
    if (status) status.textContent = text;
  },

  async copyFreeTimes() {
    const days = periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
    const text = formatFreeTimes(this.bookable.windows, days, { timezone: this.bookable.timezone, timeFormat: this.settings.time_format, strings: this.strings });
    try {
      await navigator.clipboard.writeText(text);
      this.explainerStatus(this.strings.copied);
    } catch (_error) {
      this.explainerStatus(this.strings.copy_failed);
    }
  },

  blockTime(button) {
    button.disabled = true;
    this.explainerStatus(this.strings.blocking);
    this.pushEventTo(this.el, "calendar:block", { start: button.dataset.start, end: button.dataset.end }, (reply) => {
      if (reply?.accepted) return this.closeExplainer();
      button.disabled = false;
      this.explainerStatus(reply?.error || this.strings.block_refused);
      return undefined;
    });
  },
};
