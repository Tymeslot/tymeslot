/**
 * Touch dragging and selection for the CalendarCanvas hook (mixed into it).
 *
 * DragMixin leaves touch alone, because a finger on the grid is first of all
 * a scroll. Here a finger that rests LONG_PRESS_MS on an event the organiser
 * can move, without wandering more than PRESS_SLOP, starts the same drag a
 * mouse starts (it fills `this.press` and calls `startDrag`); from then on
 * DragMixin's own pointermove, pointerup and pointercancel handlers carry it
 * to the drop, the cache update and `calendar:move`. A move, a lift, a second
 * finger or a scroll before then cancels the press, and a lift's click opens
 * the event as it always has.
 *
 * On a coarse pointer, opening an event also selects it (`select`, called
 * from `open`): `decorate`, run after every redraw, rings the block and, when
 * it can be resized, puts a handle under its bottom edge, outside the block
 * so it never covers the title. A press on the handle starts an "end" resize
 * at once. The selection survives redraws and the preview closing (on a
 * phone the preview's scrim covers the grid, and the handle must still be
 * there after it); Escape or a tap on the empty grid lets go.
 *
 * While a touch drag is live, touchmove is cancelled so the page does not
 * scroll under the finger, and neither the context menu a long-press raises
 * nor the capture moving from the block to the canvas cancels the drag.
 */
import { draggable, slotAt } from "../../calendar/drag.js";
import { LONG_PRESS_MS, movedBeyond } from "../../calendar/gestures.js";
import { MINUTES_PER_DAY } from "../../calendar/time.js";
import { isCoarse } from "../../calendar/viewport.js";

export const TouchDragMixin = {
  mountTouchDrag() {
    this.touchPress = null;
    this.selectedId = null;
    this.touchListeners = [
      ["pointerdown", (e) => this.touchDown(e)],
      ["pointermove", (e) => this.touchMove(e)],
      ["pointerup", (e) => this.touchLift(e)],
      ["pointercancel", (e) => this.touchLift(e)],
    ];
    for (const [name, listener] of this.touchListeners) this.el.addEventListener(name, listener);
    // Capture phase: these run before DragMixin's cancelling listeners on the
    // same element. Scroll does not bubble, so it is caught here too.
    this.touchCaptures = [
      ["contextmenu", (e) => this.touchContextMenu(e)],
      ["lostpointercapture", (e) => this.touchLostCapture(e)],
      ["scroll", () => this.cancelPress()],
    ];
    for (const [name, listener] of this.touchCaptures) this.el.addEventListener(name, listener, true);
    // Not passive: a live drag must stop the page scrolling under the finger.
    this.touchGuard = (e) => {
      if (this.drag) e.preventDefault();
    };
    this.el.addEventListener("touchmove", this.touchGuard, { passive: false });
  },

  destroyTouchDrag() {
    for (const [name, listener] of this.touchListeners || []) this.el.removeEventListener(name, listener);
    for (const [name, listener] of this.touchCaptures || []) this.el.removeEventListener(name, listener, true);
    this.el.removeEventListener("touchmove", this.touchGuard);
    this.cancelPress();
  },

  touchDown(e) {
    if (e.pointerType !== "touch" || !this.settings) return;
    // A second finger is a pinch, or a slip, never a long-press.
    if (this.touchPress) {
      this.cancelPress();
      return;
    }
    if (this.drag) return;
    const handle = e.target.closest?.("[data-touch-handle]");
    if (handle && this.el.contains(handle)) {
      this.startHandleResize(handle, e);
      return;
    }
    const target = e.target.closest?.(".cal-col .cal-ev[data-editable]");
    if (!target || !this.el.contains(target)) return;
    const event = this.cache.events.get(target.dataset.eventId);
    if (!event || !draggable(event)) return;
    target.classList.add("is-pressing");
    this.touchPress = {
      event,
      target,
      start: { x: e.clientX, y: e.clientY },
      pointerId: e.pointerId,
      timer: setTimeout(() => this.longPress(), LONG_PRESS_MS),
    };
  },

  touchMove(e) {
    const press = this.touchPress;
    if (press && e.pointerId === press.pointerId && movedBeyond(press.start, { x: e.clientX, y: e.clientY })) this.cancelPress();
  },

  // A lift before the long-press is a tap: its click opens the event.
  touchLift(e) {
    if (this.touchPress && this.touchPress.pointerId === e.pointerId) this.cancelPress();
  },

  cancelPress() {
    if (!this.touchPress) return;
    clearTimeout(this.touchPress.timer);
    this.touchPress.target.classList.remove("is-pressing");
    this.touchPress = null;
  },

  // The finger rested long enough: the press becomes DragMixin's, as a
  // mouse press past the threshold would, and the event is selected so its
  // handle is there after the drop.
  longPress() {
    const { event, target, start, pointerId } = this.touchPress;
    this.touchPress = null;
    target.classList.remove("is-pressing");
    // A redraw since the press detached the block: the finger is on a new one, so the press is void.
    if (!target.isConnected) return;
    this.press = { event, target, mode: "move", x: start.x, y: start.y, pointerId, touch: true, slot: slotAt(start, this.gridGeometry()) };
    if (this.startDrag()) this.select(event.id);
  },

  // A press on the selected event's handle resizes its end at once. The
  // finger lands below the edge it holds, so the drag is shifted to keep the
  // end on the edge rather than jumping to the finger.
  startHandleResize(handle, e) {
    const id = handle.dataset.touchHandle;
    const target = this.blockFor(id);
    const event = this.cache.events.get(id);
    if (!target || !event || !draggable(event)) return;
    e.preventDefault();
    const point = { x: e.clientX, y: e.clientY };
    const geometry = this.gridGeometry();
    this.press = { event, target, mode: "end", x: point.x, y: point.y, pointerId: e.pointerId, touch: true, slot: slotAt(point, geometry) };
    if (!this.startDrag()) return;
    handle.remove();
    const edge = geometry.top + geometry.scale.yOf(event.endMin - event.startDay * MINUTES_PER_DAY);
    this.drag.shiftY = edge - point.y;
  },

  touchContextMenu(e) {
    if (!this.touchPress && !this.press?.touch) return;
    e.preventDefault();
    e.stopPropagation();
  },

  // startDrag captures the pointer on the canvas, which for a finger moves
  // the capture off the pressed block: that is not the drag being lost.
  touchLostCapture(e) {
    if (this.press?.touch && e.target !== this.el) e.stopPropagation();
  },

  // Chooses the event a finger tapped or picked up; with a mouse there is no selection.
  select(id) {
    this.selectedId = isCoarse() ? id : null;
    this.decorate();
  },

  // True when an event was selected.
  clearSelection() {
    if (!this.selectedId) return false;
    this.selectedId = null;
    this.decorate();
    return true;
  },

  // The block of the event with this id, or null for none (and for no id).
  blockFor(id) {
    if (!id) return null;
    return [...this.el.querySelectorAll(".cal-col .cal-ev[data-event-id]")].find((node) => node.dataset.eventId === id) ?? null;
  },

  // Marks the selected block and puts its handle in its column. A live drag
  // owns the blocks until the drop, whose redraw calls this again.
  decorate() {
    if (this.drag) return;
    for (const node of this.el.querySelectorAll("[data-touch-handle]")) node.remove();
    for (const node of this.el.querySelectorAll(".cal-ev.is-selected")) node.classList.remove("is-selected");
    if (!this.selectedId) return;
    const target = this.blockFor(this.selectedId);
    // A selection with no block on screen (the event is gone, or the view has none) is let go.
    if (!target) {
      this.selectedId = null;
      return;
    }
    target.classList.add("is-selected");
    if (!target.hasAttribute("data-editable")) return;
    const handle = document.createElement("span");
    handle.className = "cal-touch-handle";
    handle.dataset.touchHandle = this.selectedId;
    handle.setAttribute("aria-hidden", "true");
    handle.style.top = `${parseFloat(target.style.top) + parseFloat(target.style.height)}px`;
    for (const name of ["--l", "--w", "--cal-ev"]) handle.style.setProperty(name, target.style.getPropertyValue(name));
    target.parentElement.appendChild(handle);
  },
};
