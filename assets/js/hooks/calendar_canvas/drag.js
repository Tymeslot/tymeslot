/**
 * Drag to move and resize, for the CalendarCanvas hook (mixed into it).
 *
 * A press on a draggable block (`data-editable`) becomes a drag once the
 * pointer has travelled DRAG_THRESHOLD pixels; a press on one of its grips
 * resizes that edge. While dragging, the block itself follows the snapped
 * range (moved into the target day's column, its top and height set from
 * the range) and shows its new time; every redraw waits (`render` checks
 * `this.drag`), so a payload arriving mid-drag cannot tear the block away.
 * Nothing reaches the server until the drop: then the new time goes into
 * the cache at once (`commitMove`) and `calendar:move` asks the server to
 * make it so. The server answers with the window either way, which
 * replaces this guess. Escape, a context menu, a lost pointer capture or a
 * move with no button held cancels; only the pointer that pressed counts.
 * The columns' position is read afresh on every move, and a scroll (or the
 * auto-scroll near the scroller's edge) re-runs the last move, so the block
 * stays under the pointer. Touch enters through touch_drag.js, which
 * fills `this.press` after a long-press and calls `startDrag`.
 */
import { DRAG_THRESHOLD, beginDrag, dragRange, draggable, previewBox, slotAt } from "../../calendar/drag.js";
import { MINUTES_PER_DAY, formatMinutes, formatWall, isoFromDay, normaliseEvent, periodDays } from "../../calendar/time.js";

const EDGE = 32; // px from the scroller's edge where auto-scroll starts
const MAX_SCROLL_STEP = 18; // px per frame, at the very edge

const samePointer = (press, e) => press.pointerId === undefined || e.pointerId === undefined || press.pointerId === e.pointerId;

export const DragMixin = {
  mountDrag() {
    this.press = null;
    this.drag = null;
    this.swallowClick = false;
    this.swallowTimer = null;
    this.scrollFrame = null;
    this.escaped = false;
    this.escapeListener = (e) => {
      if (e.key === "Escape") this.escapeDrag();
    };
    this.scrollListener = () => this.followPointer();
    this.dragListeners = [
      ["pointerdown", (e) => this.pointerDown(e)],
      ["pointermove", (e) => this.pointerMove(e)],
      ["pointerup", (e) => this.pointerUp(e)],
      ["pointercancel", (e) => this.pointerCancel(e)],
      ["contextmenu", () => this.cancelDrag()],
      ["lostpointercapture", () => this.cancelDrag()],
    ];
    for (const [name, listener] of this.dragListeners) this.el.addEventListener(name, listener);
    // Scroll does not bubble, so listen in the capture phase.
    this.el.addEventListener("scroll", this.scrollListener, true);
  },

  destroyDrag() {
    for (const [name, listener] of this.dragListeners || []) this.el.removeEventListener(name, listener);
    this.el.removeEventListener("scroll", this.scrollListener, true);
    document.removeEventListener("keydown", this.escapeListener);
    this.stopAutoScroll();
    clearTimeout(this.swallowTimer);
    this.press = null;
    this.drag = null;
  },

  // Escape ends a live drag. The release that follows (however late) is
  // still the drag's, so its click stays swallowed until then.
  escapeDrag() {
    if (!this.cancelDrag()) return false;
    this.swallowClick = true;
    this.escaped = true;
    return true;
  },

  // The click that follows a drag's release is not a click; it is gone by the next tick.
  swallowNextClick() {
    this.swallowClick = true;
    clearTimeout(this.swallowTimer);
    this.swallowTimer = setTimeout(() => {
      this.swallowClick = false;
    }, 0);
  },

  pointerDown(e) {
    this.swallowClick = false;
    this.escaped = false;
    // A second pointer cannot take over a live drag; it replaces a mere press.
    if (this.drag && !samePointer(this.press, e)) return;
    if (e.button !== 0 || e.pointerType === "touch" || !this.settings) return;
    const target = e.target.closest?.(".cal-col .cal-ev[data-editable]");
    if (!target || !this.el.contains(target)) return;
    const event = this.cache.events.get(target.dataset.eventId);
    if (!event || !draggable(event)) return;

    const grip = e.target.closest("[data-grip]");
    this.press = {
      event,
      target,
      mode: grip ? grip.dataset.grip : "move",
      x: e.clientX,
      y: e.clientY,
      pointerId: e.pointerId,
    };
    this.press.slot = slotAt({ x: e.clientX, y: e.clientY }, this.gridGeometry());
  },

  pointerMove(e) {
    if (!this.press || !samePointer(this.press, e)) return;
    // The button was released where we could not see it (a context menu, a
    // window switch): the drag is over, whatever the pointer does next.
    if (e.buttons === 0) {
      this.cancelDrag();
      return;
    }
    this.press.last = { x: e.clientX, y: e.clientY };
    if (!this.drag) {
      if (Math.hypot(e.clientX - this.press.x, e.clientY - this.press.y) < DRAG_THRESHOLD) return;
      if (!this.startDrag()) return;
    }
    e.preventDefault();
    this.drag.last = { x: e.clientX, y: e.clientY };
    this.followPointer();
    this.autoScroll();
  },

  // True when the drag began; false when its block is gone.
  startDrag() {
    const { event, mode, slot, pointerId } = this.press;
    let target = this.press.target;
    this.cancelMove?.({ announce: false });
    this.closeList();
    // Closing the list may have redrawn the grid and detached the pressed block.
    if (!target.isConnected) {
      target = this.el.querySelector(`.cal-col .cal-ev[data-event-id="${CSS.escape(event.id)}"]`);
      if (!target) {
        this.press = null;
        return false;
      }
    }
    const label = document.createElement("span");
    label.className = "cal-drag-time";
    label.setAttribute("aria-hidden", "true");
    target.appendChild(label);
    target.classList.add("is-dragging");
    if (pointerId !== undefined) this.el.setPointerCapture?.(pointerId);
    document.addEventListener("keydown", this.escapeListener);
    this.drag = { state: beginDrag(mode, event, slot), target, label, last: null, range: { startMin: event.startMin, endMin: event.endMin } };
    return true;
  },

  // Works out the range under the pointer's last position, from where the
  // columns are now (they move when the grid scrolls).
  followPointer() {
    if (!this.drag?.last) return;
    const geometry = this.gridGeometry();
    // A touch resize holds the edge from below it (touch_drag.js): shiftY puts the pointer back on the edge.
    const { x, y } = this.drag.last;
    this.drag.range = dragRange(this.drag.state, slotAt({ x, y: y + (this.drag.shiftY ?? 0) }, geometry), geometry.scale.firstMinute);
    this.drawDrag(geometry);
  },

  drawDrag(geometry) {
    const { target, label, range } = this.drag;
    const iso = isoFromDay(Math.floor(range.startMin / MINUTES_PER_DAY));
    const column = this.el.querySelector(`.cal-col[data-day="${iso}"]`);
    if (column && target.parentElement !== column) column.appendChild(target);
    const box = previewBox(range, geometry.scale);
    target.style.top = `${box.top}px`;
    target.style.height = `${box.height}px`;
    const tf = this.settings.time_format;
    // An end at midnight reads 00:00, as the grid's own times do.
    label.textContent = `${formatMinutes(range.startMin % MINUTES_PER_DAY, tf)}–${formatMinutes(range.endMin % MINUTES_PER_DAY, tf)}`;
  },

  // While the pointer is near the scroller's top or bottom edge, scrolls it
  // a frame at a time, within its range.
  autoScroll() {
    const speed = this.scrollSpeed();
    if (!speed) {
      this.stopAutoScroll();
      return;
    }
    if (this.scrollFrame) return;
    const step = () => {
      this.scrollFrame = null;
      if (!this.drag) return;
      const velocity = this.scrollSpeed();
      const scroller = this.el.querySelector("[data-scroll]");
      if (!velocity || !scroller) return;
      const max = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
      const next = Math.min(max, Math.max(0, scroller.scrollTop + velocity));
      if (next === scroller.scrollTop) return;
      scroller.scrollTop = next; // the scroll event re-runs the pointer's move
      this.scrollFrame = requestAnimationFrame(step);
    };
    this.scrollFrame = requestAnimationFrame(step);
  },

  stopAutoScroll() {
    if (this.scrollFrame) cancelAnimationFrame(this.scrollFrame);
    this.scrollFrame = null;
  },

  // Pixels to scroll per frame for the pointer's last position: negative near
  // the top edge, positive near the bottom, faster the closer to the edge.
  scrollSpeed() {
    const scroller = this.el.querySelector("[data-scroll]");
    const last = this.drag?.last;
    if (!scroller || !last) return 0;
    const rect = scroller.getBoundingClientRect();
    // The headings and the all-day lane stick to the scroller's top, so the grid's visible top is below them.
    const top = this.el.querySelector(".cal-top")?.getBoundingClientRect().bottom ?? rect.top;
    if (last.y >= rect.top && last.y < top) return 0; // over the headings themselves
    if (last.y < top + EDGE) return -Math.ceil(MAX_SCROLL_STEP * Math.min(1, (top + EDGE - last.y) / EDGE));
    if (last.y > rect.bottom - EDGE) return Math.ceil(MAX_SCROLL_STEP * Math.min(1, (last.y - (rect.bottom - EDGE)) / EDGE));
    return 0;
  },

  pointerUp(e) {
    if (this.press && !samePointer(this.press, e)) return;
    const wasDragging = !!this.drag;
    const { state, range } = this.drag || {};
    this.endDrag();
    if (this.escaped) {
      this.escaped = false;
      this.swallowNextClick();
    }
    if (!wasDragging) return;
    this.swallowNextClick();
    if (range.startMin !== state.startMin || range.endMin !== state.endMin) this.commitMove(state.id, range);
    else this.render();
  },

  pointerCancel(e) {
    if (this.press && !samePointer(this.press, e)) return;
    this.cancelDrag();
  },

  // Forgets the press and the drag without drawing anything.
  endDrag() {
    this.press = null;
    this.drag = null;
    this.stopAutoScroll();
    document.removeEventListener("keydown", this.escapeListener);
  },

  // True when a drag was in progress.
  cancelDrag() {
    const wasDragging = !!this.drag;
    this.endDrag();
    if (wasDragging) this.render();
    return wasDragging;
  },

  // Shows the new time at once and asks the server to make it so.
  commitMove(id, range) {
    const start = formatWall(range.startMin);
    const end = formatWall(range.endMin);
    const event = this.cache.events.get(id);
    if (event) this.cache.events.set(id, normaliseEvent({ ...event, start, end }));
    this.render();
    // A series event asks which events to change; focus returns after that modal.
    this.watchModal?.(id);
    this.pushEventTo(this.el, "calendar:move", { id, start, end });
  },

  // Where the day columns are on screen, and the scale they are drawn at.
  gridGeometry() {
    const cols = this.el.querySelector(".cal-cols");
    const days = periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
    const rect = cols ? cols.getBoundingClientRect() : { left: 0, top: 0, width: 0 };
    return { left: rect.left, top: rect.top, colWidth: rect.width / Math.max(1, days.length), days, scale: this.currentScale() };
  },
};
