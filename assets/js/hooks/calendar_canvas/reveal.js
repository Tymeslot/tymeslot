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
 * closes (`open`'s `returnTo`). A period still pending is no reason to wait:
 * the hook's `calendar:goto` reaches the server before its `calendar:open`.
 * Six seconds without finding it, the hook gives up with its notice.
 */
import { needsNight, revealTarget } from "../../calendar/reveal.js";
import { isTimeGrid } from "../../calendar/time.js";

const REVEAL_MS = 6000;

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
    this.reveal = { ids, until: Date.now() + REVEAL_MS };
    if (needsNight(startMin, allDay, this.settings, this.nightOpen)) this.nightOpen = true;
    if (isTimeGrid(this.viewFor(this.view)) && !allDay && startMin != null) {
      this.scrollTarget = startMin;
      this.scrollDate = date;
      this.scrollTop = null;
    }
    this.revealTimer = setTimeout(() => this.afterReveal(), REVEAL_MS);
    this.gotoPeriod(this.view, date);
    // The same days needed no navigation: draw them again for the night and
    // the scroll; the draw looks for the event.
    if (!this.pending) this.render();
  },

  afterReveal() {
    const reveal = this.reveal;
    if (!reveal) return undefined;
    if (Date.now() >= reveal.until) return this.revealMissed();
    if (!this.settings || this.drag || this.createDrag) return undefined;
    const target = revealTarget(this.el, reveal.ids, this.cache);
    if (!target) return undefined;
    this.endReveal();
    return this.openRevealed(target);
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

  revealMissed() {
    this.endReveal();
    const text = this.strings.reveal_missed;
    this.announce(text);
    this.showNotice(text, "reveal");
    // Only when focus has nowhere to be: a late miss never pulls it from where the organiser went.
    if (document.activeElement === document.body) this.restoreQuickFocus(null);
  },

  endReveal() {
    clearTimeout(this.revealTimer);
    this.revealTimer = null;
    this.reveal = null;
  },
};
