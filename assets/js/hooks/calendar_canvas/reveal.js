/**
 * Search reveal, for the CalendarCanvas hook (mixed into it): the command
 * bar's search rows (command.js) bring an event into view and open its
 * preview, even when it hides behind "+N" or in the folded early hours.
 *
 * `revealEvent` moves the view the organiser is in to the event's date (a
 * phone keeps its 3 days or month, through `gotoPeriod` and `viewFor`),
 * unfolds the night for a timed event before 07:00 and asks the time grid
 * to scroll to the event (`scrollTarget`, as the bookable note's Show
 * does). Every draw then calls `afterReveal` (views.js `afterView`), which
 * looks for the event once its days are drawn (calendar/reveal.js): an
 * event drawn as itself opens from its block; one behind a "+N" chip opens
 * from that chip's list, so focus goes back to the chip when the preview
 * closes (`open`'s `returnTo`). The reveal is armed only after `gotoPeriod`
 * has pushed `calendar:goto`, so `calendar:open` never reaches the server
 * first; the search runs on a microtask, once the draw and its scroll are
 * done. It ends silently when the organiser moves on (another period,
 * preview or quick create).
 * Six seconds without finding it, the hook gives up with its notice.
 */
import { needsNight, revealTarget } from "../../calendar/reveal.js";
import { isTimeGrid, periodDays } from "../../calendar/time.js";

const REVEAL_MS = 6000;
const REVEAL_NOTICE = "reveal-missed";
const isWeekend = (iso) => [0, 6].includes(new Date(`${iso}T00:00:00Z`).getUTCDay());

export const RevealMixin = {
  mountReveal() {
    this.reveal = null;
    this.revealTimer = null;
  },

  destroyReveal() {
    this.endReveal();
  },

  revealEvent({ ids, date, startMin = null, allDay = false }) {
    if (!ids?.length || !date || !this.settings) return;
    this.endReveal();
    // A weekend day has no column in a week without weekends: show it as a day.
    if (this.viewFor(this.view) === "week" && !this.settings.show_weekends && isWeekend(date)) this.view = "day";
    const timeGrid = isTimeGrid(this.viewFor(this.view));
    if (timeGrid && needsNight(startMin, allDay, this.settings, this.nightOpen)) this.nightOpen = true;
    if (timeGrid && !allDay && startMin != null) {
      this.scrollTarget = startMin;
      this.scrollDate = date;
      this.scrollTop = null;
    }
    this.gotoPeriod(this.view, date);
    // The same days needed no navigation: draw them again for the night and the scroll.
    if (!this.pending) this.render();
    const reveal = { ids, date, view: this.view, opened: this.lastOpened };
    this.reveal = reveal;
    this.revealTimer = setTimeout(() => this.tryReveal(reveal, true), REVEAL_MS);
    this.afterReveal();
  },

  // Called after every draw (views.js `afterView`) and once armed: the search
  // waits for the draw to finish, so the scroll is applied.
  afterReveal() {
    const reveal = this.reveal;
    if (!reveal || reveal.queued) return;
    reveal.queued = true;
    queueMicrotask(() => {
      reveal.queued = false;
      this.tryReveal(reveal, false);
    });
  },

  tryReveal(reveal, final) {
    if (this.reveal !== reveal) return;
    if (this.quick || this.lastOpened !== reveal.opened) return this.endReveal();
    if (this.settings && !this.pending && !this.revealDrawn(reveal.date)) return this.revealShown(reveal) ? this.revealMissed() : this.endReveal();
    const target = this.settings && !this.drag && !this.createDrag ? revealTarget(this.el, reveal.ids, this.cache) : null;
    if (target?.node.isConnected) {
      this.endReveal();
      return this.openRevealed(target);
    }
    return final ? this.revealMissed() : undefined;
  },

  // Whether the organiser is still in the period the reveal asked for.
  revealShown(reveal) {
    return this.view === reveal.view && periodDays(this.view, this.date, this.settings.week_start, true).includes(reveal.date);
  },

  revealDrawn(date) {
    return periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends).includes(date);
  },

  openRevealed({ kind, node, id }) {
    if (kind === "event") {
      node.scrollIntoView?.({ block: "nearest" });
      return this.open(id, node);
    }
    // The chip's own click opens its list (the hook's handlers).
    node.click();
    const item = this.list ? [...this.list.querySelectorAll("[data-event-id]")].find((button) => button.dataset.eventId === id) : null;
    return item ? this.open(id, item) : this.revealMissed();
  },

  // The notice is a role="alert", which announces it.
  revealMissed() {
    this.endReveal();
    this.showNotice(this.strings.reveal_missed, REVEAL_NOTICE);
    // Only when focus has nowhere to be: a late miss never pulls it from where the organiser went.
    if (document.activeElement === document.body) this.restoreQuickFocus(null);
  },

  endReveal() {
    clearTimeout(this.revealTimer);
    this.revealTimer = null;
    this.reveal = null;
  },
};
