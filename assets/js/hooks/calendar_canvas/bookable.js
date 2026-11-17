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
 * follows at once and the hook pushes `calendar:bookable_toggle` with the
 * state it now shows (`on`) for the server to save; a refusal pushes the
 * layer back as it was. The note's Show goes to the next bookable time's
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
import { applyPlacement, placeOverlay, releaseSheet } from "../../calendar/sheet.js";
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
      const inExplainer = !!target?.closest?.("#calendar-bookable-explainer");
      if (target?.isContentEditable || (!inExplainer && target?.closest?.(`${TYPING}, [role="dialog"], dialog`)) || document.querySelector(MODALS)) return;
      e.preventDefault();
      this.toggleBookable();
    };
    // A press on a label is left to its click, which toggles the explainer;
    // one on a sheet's scrim to the scrim's click, which closes it.
    this.explainerOutside = (e) => {
      if (e.target.closest?.("[data-sheet-scrim]")) return;
      if (this.explainer && !this.explainer.contains(e.target) && !e.target.closest?.("[data-bookable-label]")) this.closeExplainer();
    };
    document.addEventListener("keydown", this.bookableKey);
    this.handleEvent("calendar:bookable", (layer) => this.receiveBookable(layer));
  },

  destroyBookable() {
    document.removeEventListener("keydown", this.bookableKey);
    document.removeEventListener("pointerdown", this.explainerOutside);
    this.dropExplainer();
  },

  // Whether a popover over the grid holds redraws back until it closes.
  overlayOpen() {
    return !!(this.list || this.explainer);
  },

  receiveBookable(layer) {
    this.bookable = layer;
    this.settleOpenings();
    if (this.overlayOpen()) {
      this.dirty = true;
      return;
    }
    this.render();
  },

  // The push names the state wanted, not a flip, so two quick presses
  // cannot cross on the way. A refused change comes back as the layer the
  // server holds, which redraws the grid as it was. Before the first layer
  // arrives the hook cannot know the state, so it asks for a flip.
  toggleBookable() {
    this.closeExplainer();
    if (!this.bookable) {
      this.pushEventTo(this.el, "calendar:bookable_toggle", {});
      return;
    }
    const on = !this.bookable.on;
    this.bookable = { ...this.bookable, on };
    this.render();
    this.pushEventTo(this.el, "calendar:bookable_toggle", { on });
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
    applyPlacement(explainer, placeOverlay(anchor.getBoundingClientRect(), size, viewport(), { sheet: this.sheetMode() }));
    explainer.addEventListener("calendar:dismiss", () => this.closeExplainer());
    this.explainer = explainer;
    this.explainerDay = day;
    anchor.setAttribute("aria-expanded", "true");
    document.addEventListener("pointerdown", this.explainerOutside);
    explainer.querySelector("button")?.focus();
  },

  // Forget the explainer without touching focus (a redraw has removed it).
  dropExplainer() {
    releaseSheet(this.explainer);
    document.removeEventListener("pointerdown", this.explainerOutside);
    this.el.querySelector(`[data-bookable-label="${this.explainerDay}"]`)?.setAttribute("aria-expanded", "false");
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
    const copied = (await this.writeClipboard(text)) || this.copyWithCommand(text);
    this.explainerStatus(copied ? this.strings.copied : this.strings.copy_failed);
  },

  async writeClipboard(text) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch (_error) {
      return false;
    }
  },

  // For browsers without the clipboard API, or that refuse it here: select a
  // hidden field and use the older copy command.
  copyWithCommand(text) {
    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.cssText = "position:fixed;top:0;left:-9999px;opacity:0";
    document.body.appendChild(field);
    const focused = document.activeElement;
    try {
      field.select();
      return !!document.execCommand?.("copy");
    } catch (_error) {
      return false;
    } finally {
      field.remove();
      focused?.focus?.({ preventScroll: true });
    }
  },

  blockTime(button) {
    const explainer = this.explainer;
    const day = this.explainerDay;
    button.disabled = true;
    this.explainerStatus(this.strings.blocking);
    this.pushEventTo(this.el, "calendar:block", { start: button.dataset.start, end: button.dataset.end }, (reply) => {
      // The explainer may have closed, or another opened, while the server worked.
      if (this.explainer !== explainer) return undefined;
      if (reply?.accepted) {
        this.closeExplainer();
        return this.focusBy({ attr: "data-bookable-label", value: day });
      }
      button.disabled = false;
      this.explainerStatus(reply?.error || this.strings.block_refused);
      return undefined;
    });
  },
};
