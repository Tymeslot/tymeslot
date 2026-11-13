/**
 * The CalendarCanvas hook's "+N" list (mixed into it): the events a time
 * grid chip, an all-day "+N" or a month day's "+N" stands for, drawn by
 * `renderList` beside its anchor, or as a bottom sheet on a phone
 * (calendar/sheet.js).
 *
 * `showList` toggles: a second press on the same anchor closes the list. A
 * press anywhere outside the list and its anchor closes it (`outside`, a
 * document listener while it is open); a sheet's scrim is left to its own
 * click. `closeList` hands focus back to the anchor when the list had it and
 * draws the redraw the open list deferred (`dirty`); `dropList` forgets the
 * list without touching focus, for a redraw that has removed it already.
 */
import { renderList } from "../../calendar/render.js";
import { applyPlacement, placeOverlay, releaseSheet } from "../../calendar/sheet.js";

const viewport = () => ({ width: window.innerWidth, height: window.innerHeight });

export const ListMixin = {
  mountList() {
    this.list = null;
    this.listAnchor = null;
    this.outside = (e) => {
      // A press on the chip itself is left to its click, which toggles the
      // list; one on a sheet's scrim to the scrim's click, which closes it.
      if (e.target.closest?.("[data-sheet-scrim]")) return;
      if (this.list && !this.list.contains(e.target) && !this.listAnchorEl?.contains(e.target)) this.closeList();
    };
  },

  destroyList() {
    this.closeList();
  },

  showList(events, anchor, label) {
    const reopening = this.list && this.listAnchorEl === anchor;
    this.closeList();
    this.closeExplainer();
    if (reopening) return;
    const holder = document.createElement("div");
    holder.innerHTML = renderList([...events].sort((a, b) => a.startMin - b.startMin), { strings: this.strings, timeFormat: this.settings.time_format, label });
    const list = holder.firstElementChild;
    this.el.appendChild(list);

    const size = { width: list.offsetWidth || 240, height: list.offsetHeight || 160 };
    applyPlacement(list, placeOverlay(anchor.getBoundingClientRect(), size, viewport(), { sheet: this.sheetMode() }));
    list.addEventListener("calendar:dismiss", () => this.closeList());
    this.list = list;
    this.listAnchor = this.focusKeyOf(anchor);
    this.listAnchorEl = anchor;
    document.addEventListener("pointerdown", this.outside);
    list.querySelector("button")?.focus();
  },

  // Forget the list without touching focus (the grid redraw has removed it,
  // or is about to); its sheet state goes with it.
  dropList() {
    releaseSheet(this.list);
    document.removeEventListener("pointerdown", this.outside);
    this.list = null;
    this.listAnchorEl = null;
    this.dirty = false;
  },

  closeList() {
    if (!this.list) return;
    const hadFocus = this.list.contains(document.activeElement);
    const stale = this.dirty;
    this.list.remove();
    this.dropList();
    if (stale) this.render();
    if (hadFocus) this.focusBy(this.listAnchor);
  },
};
