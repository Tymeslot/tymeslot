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
 * replaces this guess. Escape cancels. Touch is left to the phone layout.
 */
import { DRAG_THRESHOLD, beginDrag, dragRange, draggable, previewBox, slotAt } from "../../calendar/drag.js";
import { MINUTES_PER_DAY, formatMinutes, formatWall, isoFromDay, normaliseEvent, periodDays } from "../../calendar/time.js";

export const DragMixin = {
  mountDrag() {
    this.press = null;
    this.drag = null;
    this.swallowClick = false;
    this.dragListeners = [
      ["pointerdown", (e) => this.pointerDown(e)],
      ["pointermove", (e) => this.pointerMove(e)],
      ["pointerup", () => this.pointerUp()],
      ["pointercancel", () => this.cancelDrag()],
    ];
    for (const [name, listener] of this.dragListeners) this.el.addEventListener(name, listener);
  },

  destroyDrag() {
    for (const [name, listener] of this.dragListeners || []) this.el.removeEventListener(name, listener);
  },

  pointerDown(e) {
    this.swallowClick = false;
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
      geometry: this.gridGeometry(),
    };
    this.press.slot = slotAt({ x: e.clientX, y: e.clientY }, this.press.geometry);
  },

  pointerMove(e) {
    if (!this.press) return;
    if (!this.drag) {
      if (Math.hypot(e.clientX - this.press.x, e.clientY - this.press.y) < DRAG_THRESHOLD) return;
      this.startDrag();
    }
    e.preventDefault();
    const { state, geometry } = this.drag;
    this.drag.range = dragRange(state, slotAt({ x: e.clientX, y: e.clientY }, geometry), geometry.scale.firstMinute);
    this.drawDrag();
  },

  startDrag() {
    const { event, target, mode, slot, pointerId, geometry } = this.press;
    this.closeList();
    const label = document.createElement("span");
    label.className = "cal-drag-time";
    label.setAttribute("aria-hidden", "true");
    target.appendChild(label);
    target.classList.add("is-dragging");
    if (pointerId !== undefined) this.el.setPointerCapture?.(pointerId);
    this.drag = { state: beginDrag(mode, event, slot), geometry, target, label, range: { startMin: event.startMin, endMin: event.endMin } };
  },

  drawDrag() {
    const { target, label, range, geometry } = this.drag;
    const iso = isoFromDay(Math.floor(range.startMin / MINUTES_PER_DAY));
    const column = this.el.querySelector(`.cal-col[data-day="${iso}"]`);
    if (column && target.parentElement !== column) column.appendChild(target);
    const box = previewBox(range, geometry.scale);
    target.style.top = `${box.top}px`;
    target.style.height = `${box.height}px`;
    const tf = this.settings.time_format;
    label.textContent = `${formatMinutes(range.startMin % MINUTES_PER_DAY, tf)}–${formatMinutes(range.endMin % MINUTES_PER_DAY, tf)}`;
  },

  pointerUp() {
    this.press = null;
    if (!this.drag) return;
    const { state, range } = this.drag;
    this.drag = null;
    this.swallowClick = true;
    if (range.startMin !== state.startMin || range.endMin !== state.endMin) this.commitMove(state.id, range);
    else this.render();
  },

  // True when a drag was in progress.
  cancelDrag() {
    this.press = null;
    if (!this.drag) return false;
    this.drag = null;
    this.render();
    return true;
  },

  // Shows the new time at once and asks the server to make it so.
  commitMove(id, range) {
    const start = formatWall(range.startMin);
    const end = formatWall(range.endMin);
    const event = this.cache.events.get(id);
    if (event) this.cache.events.set(id, normaliseEvent({ ...event, start, end }));
    this.render();
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
