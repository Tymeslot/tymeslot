/**
 * The CalendarCanvas hook's keyboard (mixed into it).
 *
 * The grid is one tab stop: after every draw one event block gets
 * tabindex 0 (the one last focused, else the first) and focus moving
 * between blocks carries it along. On a focused block the arrow keys, Home
 * and End move focus (calendar/keyboard.js) and never change data; M
 * enters the move mode, E asks the server to open the event in the side
 * panel (not while quick create is open or a modal is), Delete and Backspace
 * ask the server to delete.
 * In the move mode the arrows move the event, Shift with Up or Down
 * changes its length, Enter saves through the same path as a drop
 * (`commitMove`) and Escape cancels; each step is announced in the live
 * region the surface renders (#calendar-live), always as text: event
 * titles are user data. Ctrl Z or Cmd Z anywhere on the page but a text
 * field (a text input, a textarea, a select) asks the server to undo, in
 * the side panel too. Escape inside the side panel closes it
 * (`closePanelOnEscape`), unless a modal is open over it; so does a press on
 * its close button while a text field has focus (`closePanelOnPress`). Either
 * sends that field's value with the close, so what was being typed is saved.
 * None of it runs while a pointer drag is live. A series-scope or delete modal makes the
 * server redraw the grid behind it, which strands the focus trap's saved
 * element, so after such a modal closes focus is handed back to the
 * affected block (`watchModal`).
 */
import { cancelledText, movingText, rangeText, savingText } from "../../calendar/announce.js";
import { draggable } from "../../calendar/drag.js";
import { beginMove, moveStep, nextFocus } from "../../calendar/keyboard.js";
import { MINUTES_PER_DAY, dayNumber, formatWall, isoFromDay, normaliseEvent, periodDays } from "../../calendar/time.js";
import { MODALS, TYPING } from "../../calendar/shortcuts.js";

export { MODALS, TYPING };

const BLOCKS = ".cal-col .cal-ev[data-event-id]";
const MODAL_WATCH_MS = 10_000;
const REPEAT_ANNOUNCE_MS = 300;
const SWALLOW_CLICK_MS = 1000;
// Fields with a text undo of their own: Ctrl Z there stays the browser's.
// Anywhere else (a button, a switch, a checkbox, the side panel) it undoes
// the last change.
const TEXT_ENTRY =
  'textarea, select, [contenteditable=""], [contenteditable="true"], input:not([type="checkbox"]):not([type="radio"]):not([type="button"]):not([type="submit"]):not([type="reset"]):not([type="range"]):not([type="color"]):not([type="file"])';

export const KeysMixin = {
  mountKeys() {
    this.moving = null;
    this.activeKey = null;
    this.pendingFocus = null;
    this.modalWatch = null;
    this.modalTimer = null;
    this.announceTimer = null;
    this.undoKey = (e) => {
      if (this.drag || e.defaultPrevented || e.isComposing) return;
      if (!(e.ctrlKey || e.metaKey) || e.shiftKey || e.altKey) return;
      if (e.key?.toLowerCase() !== "z" && e.code !== "KeyZ") return;
      const target = e.target;
      if (target?.isContentEditable || target?.closest?.(`${TEXT_ENTRY}, [role="dialog"], dialog`) || document.querySelector(MODALS)) return;
      e.preventDefault();
      this.pushEventTo(this.el, "calendar:undo", {});
    };
    // LiveView only fires a phx-keydown on the element that has focus, and
    // focus in the panel is always on a field or button, so Escape is read
    // here for anything inside the panel.
    this.closePanelOnEscape = (e) => {
      if (e.key !== "Escape" || e.repeat || e.defaultPrevented || e.isComposing) return;
      if (!e.target?.closest?.("#calendar-panel") || document.querySelector(MODALS)) return;
      e.preventDefault();
      e.stopPropagation();
      this.pushPanelClose();
    };
    // A press on the panel's close button while a text field has focus: the
    // field would be gone before its blur reached the server, so the close
    // goes from here with the field's value, before the field blurs (a later
    // blur is a no-op on the server). The click that follows the press is
    // swallowed once (`swallowCloseClick`): its own plain close would shut
    // the panel even when the server kept it open for a refused value or a
    // series question. With no text field focused the button's own click
    // closes the panel.
    this.closePanelOnPress = (e) => {
      this.swallowClick = false;
      clearTimeout(this.swallowTimer);
      if ((e.button ?? 0) !== 0) return;
      if (!e.target?.closest?.("#calendar-panel-close") || !this.focusedPanelField()) return;
      e.preventDefault();
      e.stopPropagation();
      this.pushPanelClose();
      this.swallowClick = true;
      this.swallowTimer = setTimeout(() => (this.swallowClick = false), SWALLOW_CLICK_MS);
    };
    this.swallowCloseClick = (e) => {
      if (!this.swallowClick || !e.target?.closest?.("#calendar-panel-close")) return;
      this.swallowClick = false;
      clearTimeout(this.swallowTimer);
      e.preventDefault();
      e.stopPropagation();
    };
    // Focus leaving for another part of the page ends a move mode; a null
    // target is only a redraw replacing the focused block.
    this.focusOut = (e) => {
      if (this.moving && e.relatedTarget && !this.el.contains(e.relatedTarget)) this.cancelMove();
    };
    // The preview's Delete button lives outside the canvas.
    this.previewDelete = (e) => {
      if (e.target.closest?.("#calendar-preview-delete") && this.lastOpened) this.watchModal(this.lastOpened);
    };
    // Focus does not bubble; captured here it still reaches the canvas.
    this.focusIn = (e) => {
      const target = e.target.closest?.(BLOCKS);
      if (!target || !this.el.contains(target)) return;
      this.activeKey = this.focusKeyOf(target);
      for (const other of this.el.querySelectorAll(`${BLOCKS}[tabindex="0"]`)) if (other !== target) other.tabIndex = -1;
      target.tabIndex = 0;
    };
    document.addEventListener("keydown", this.undoKey);
    document.addEventListener("keydown", this.closePanelOnEscape);
    document.addEventListener("pointerdown", this.closePanelOnPress, true);
    document.addEventListener("click", this.swallowCloseClick, true);
    document.addEventListener("click", this.previewDelete);
    this.el.addEventListener("focus", this.focusIn, true);
    this.el.addEventListener("focusout", this.focusOut);
  },

  destroyKeys() {
    document.removeEventListener("keydown", this.undoKey);
    document.removeEventListener("keydown", this.closePanelOnEscape);
    document.removeEventListener("pointerdown", this.closePanelOnPress, true);
    document.removeEventListener("click", this.swallowCloseClick, true);
    clearTimeout(this.swallowTimer);
    document.removeEventListener("click", this.previewDelete);
    this.el.removeEventListener("focus", this.focusIn, true);
    this.el.removeEventListener("focusout", this.focusOut);
    clearTimeout(this.announceTimer);
    this.unwatchModal();
  },

  // The side panel's text field that has focus, if any (marked
  // data-panel-field; the server saves it as its blur would).
  focusedPanelField() {
    const field = document.activeElement?.closest?.("#calendar-panel [data-panel-field]");
    return field && !field.disabled ? field : null;
  },

  // Asks the server to close the side panel, with the focused text field and
  // its value so that what was being typed is saved first (PanelEvents). Any
  // other focused panel control is blurred first: the date and time fields
  // save on blur, and that change must reach the server before the close.
  pushPanelClose() {
    const field = this.focusedPanelField();
    const active = document.activeElement;
    if (!field && active?.closest?.("#calendar-panel")) active.blur();
    this.pushEventTo(this.el, "panel:close", field ? { field: field.dataset.panelField, value: field.value } : {});
  },

  // A key on a focused event block; true when it was handled.
  eventKey(e, target) {
    const id = target.dataset.eventId;
    const day = target.closest("[data-day]")?.dataset.day;

    if (e.key.startsWith("Arrow") || e.key === "Home" || e.key === "End") {
      // Alt or Cmd with an arrow is the browser's Back and Forward.
      if (e.altKey || e.metaKey || e.ctrlKey) return false;
      e.preventDefault();
      const next = nextFocus(this.focusItems(), { id, day: dayNumber(day) }, e.key);
      if (next && this.focusBy({ attr: "data-event-id", value: next.id, day: isoFromDay(next.day) })) document.activeElement?.scrollIntoView?.({ block: "nearest" });
      return true;
    }

    if (e.repeat || e.ctrlKey || e.metaKey || e.altKey) return false;
    const event = this.cache.events.get(id);

    if ((e.key === "m" || e.key === "M") && event && draggable(event)) {
      e.preventDefault();
      this.startMoving(event);
      return true;
    }

    if ((e.key === "e" || e.key === "E") && event?.editable && this.editKeyAllowed(e)) {
      e.preventDefault();
      this.pushEventTo(this.el, "calendar:edit", { id });
      return true;
    }

    if ((e.key === "Delete" || e.key === "Backspace") && event?.editable) {
      e.preventDefault();
      // Focus goes to a neighbour once the event has left the grid.
      const items = this.focusItems();
      const here = { id, day: dayNumber(day) };
      const next = nextFocus(items, here, "ArrowDown") || nextFocus(items, here, "ArrowUp");
      this.pendingFocus = next ? { attr: "data-event-id", value: next.id, day: isoFromDay(next.day) } : null;
      this.watchModal(id);
      this.pushEventTo(this.el, "calendar:delete", { id });
      return true;
    }

    return false;
  },

  // E opens the panel unless something else owns the keyboard: a text field,
  // a dialog or modal, quick create (open or saving), a drag or a move mode.
  editKeyAllowed(e) {
    if (e.isComposing || e.defaultPrevented || this.drag || this.createDrag || this.moving || this.quick) return false;
    // The text-field and dialog tests are defensive: E is only read on a focused event block.
    const target = e.target;
    return !(target?.isContentEditable || target?.closest?.(`${TYPING}, [role="dialog"], dialog`) || document.querySelector(MODALS));
  },

  // The blocks as drawn, for calendar/keyboard.js.
  focusItems() {
    return [...this.el.querySelectorAll(BLOCKS)].map((node, order) => {
      const event = this.cache.events.get(node.dataset.eventId);
      const day = dayNumber(node.closest("[data-day]").dataset.day);
      return { id: node.dataset.eventId, day, minute: event ? Math.max(0, event.startMin - day * MINUTES_PER_DAY) : 0, order };
    });
  },

  startMoving(event) {
    this.closeList();
    this.moving = beginMove(event);
    this.render();
    this.announce(movingText(event.title ?? "", this.moving.range, this.strings, this.settings.time_format));
  },

  movingKey(e) {
    const event = this.cache.events.get(this.moving.id);
    if (!event) {
      this.moving = null;
      return this.render();
    }
    const tf = this.settings.time_format;

    if (e.key === "Escape") {
      e.preventDefault();
      // The preview closes on any Escape that reaches the window.
      e.stopPropagation();
      this.cancelMove();
      return this.focusBy({ attr: "data-event-id", value: event.id });
    }

    if (e.key === "Enter") {
      e.preventDefault();
      const { range, original } = this.moving;
      this.moving = null;
      if (range.startMin !== original.startMin || range.endMin !== original.endMin) {
        this.watchModal(event.id);
        this.announce(savingText(event.title ?? "", range, this.strings, tf));
        this.commitMove(event.id, range);
      } else {
        this.render();
      }
      return this.focusBy({ attr: "data-event-id", value: event.id });
    }

    if (e.key.startsWith("Arrow")) {
      if (e.altKey || e.metaKey || e.ctrlKey) return undefined;
      e.preventDefault();
      const days = periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
      this.moving.range = moveStep(this.moving.range, e.key, {
        shift: e.shiftKey,
        firstMinute: this.currentScale().firstMinute,
        firstDay: dayNumber(days[0]),
        lastDay: dayNumber(days[days.length - 1]),
      });
      this.render();
      this.focusBy({ attr: "data-event-id", value: event.id });
      const text = rangeText(this.moving.range, this.strings, tf);
      // While a key repeats only where it ends up is worth reading.
      if (!e.repeat) return this.announce(text);
      clearTimeout(this.announceTimer);
      this.announceTimer = setTimeout(() => this.announce(text), REPEAT_ANNOUNCE_MS);
      return undefined;
    }

    return undefined;
  },

  // Leaves the move mode without saving. `redraw: false` for callers that
  // draw next anyway; `announce: false` where focus or the page moved on.
  cancelMove({ announce = true, redraw = true } = {}) {
    if (!this.moving) return false;
    clearTimeout(this.announceTimer);
    const { id, original } = this.moving;
    const event = this.cache.events.get(id);
    this.moving = null;
    if (redraw) this.render();
    if (announce && event) this.announce(cancelledText(event.title ?? "", original, this.strings, this.settings.time_format));
    return true;
  },

  // The cached events with the one being moved where the move mode has it.
  withMoving(events) {
    if (!this.moving) return events;
    const { id, range } = this.moving;
    return events.map((event) => (event.id === id ? normaliseEvent({ ...event, start: formatWall(range.startMin), end: formatWall(range.endMin) }) : event));
  },

  // After a draw: one tab stop, and focus kept clear of the sticky top.
  applyRoving() {
    const top = this.el.querySelector(".cal-top");
    if (top) this.el.style.setProperty("--cal-top-h", `${top.offsetHeight}px`);
    const blocks = [...this.el.querySelectorAll(BLOCKS)];
    if (!blocks.length) return;
    const key = this.activeKey;
    const named = key ? blocks.filter((node) => node.getAttribute(key.attr) === key.value) : [];
    const active = named.find((node) => key.day === undefined || node.closest("[data-day]")?.dataset.day === key.day) || named[0] || blocks[0];
    for (const node of blocks) node.tabIndex = node === active ? 0 : -1;
  },

  // Once the series or delete modal this action opens has closed, focus
  // returns to the block (or, for a deleted one, the neighbour chosen when
  // Delete was pressed), unless the organiser has put it somewhere else.
  watchModal(id) {
    this.unwatchModal();
    let seen = false;
    this.modalWatch = new MutationObserver(() => {
      if (document.querySelector(MODALS)) {
        // An open modal can wait as long as it likes; only "none appeared" times out.
        seen = true;
        clearTimeout(this.modalTimer);
        return;
      }
      if (!seen) return;
      this.unwatchModal();
      this.returnFocus(id);
    });
    this.modalWatch.observe(document.body, { childList: true, subtree: true });
    this.modalTimer = setTimeout(() => {
      this.unwatchModal();
      this.pendingFocus = null;
    }, MODAL_WATCH_MS);
  },

  unwatchModal() {
    this.modalWatch?.disconnect();
    this.modalWatch = null;
    clearTimeout(this.modalTimer);
  },

  returnFocus(id) {
    const active = document.activeElement;
    const pending = this.pendingFocus;
    this.pendingFocus = null;
    if (active && active !== document.body && active.isConnected) return;
    if (this.focusBy({ attr: "data-event-id", value: id }) || this.focusBy(pending)) return;
    this.el.querySelector(`${BLOCKS}[tabindex="0"]`)?.focus({ preventScroll: true });
  },

  announce(text) {
    clearTimeout(this.announceTimer);
    const region = document.getElementById("calendar-live");
    if (region) region.textContent = String(text ?? "");
  },
};
