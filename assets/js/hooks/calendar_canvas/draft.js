/**
 * Drafting a new event in the CalendarCanvas hook (mixed into it).
 *
 * A click on an empty part of a day column drops a draft on the quarter
 * hour under the pointer; pressing there with a mouse or pen and dragging
 * past DRAG_THRESHOLD draws one over the snapped span instead (touch is left
 * to the phone layout). A press made while something is open over the grid
 * (the quick-create popover, a "+N" list, the event preview) only closes it,
 * as it does in other calendars. While the span is drawn a lightweight
 * block follows the pointer and every redraw waits (`render` checks
 * `this.createDrag`); Escape, a lost pointer or a release elsewhere cancels.
 *
 * The draft quick create edits lives in `this.draft` and is drawn over the
 * column (calendar/render.js draws `kind: "draft"` events). Once saved or
 * handed to the side panel it moves to `this.handed` and is drawn until
 * the server's next payload, which carries the server's own copy of the
 * draft (or the created event) under the same id; `calendar:draft-cleared`
 * drops it at once. An accepted opening is drawn until the next
 * `calendar:bookable` instead (`holdOpening`), since only the layer shows it. Nothing here talks to the server: quick create does
 * (calendar_canvas/create.js).
 */
import { DRAG_THRESHOLD, previewBox, slotAt } from "../../calendar/drag.js";
import { createRange, draftEvent, draftFromRange, draftFromSlot } from "../../calendar/draft.js";
import { openingLook } from "../../calendar/opening.js";
import { MINUTES_PER_DAY, formatMinutes, isoFromDay, normaliseEvent } from "../../calendar/time.js";

// What a press on a column must not start on to count as empty.
const NOT_EMPTY = ".cal-ev, .cal-more, .cal-early, .cal-list, button, [data-draft-id], [data-touch-handle]";

const samePointer = (press, e) => press.pointerId === undefined || e.pointerId === undefined || press.pointerId === e.pointerId;

let sequence = 0;
// A draft id unique on this page: the server keys pending creates by it.
export const newDraftId = () => `d${Date.now().toString(36)}${(sequence += 1)}`;

export const DraftMixin = {
  mountDraft() {
    this.draft = null;
    this.handed = new Map();
    this.createPress = null;
    this.createDrag = null;
    this.pressHadLayer = false;
    this.createEscape = (e) => {
      if (e.key !== "Escape" || !this.createDrag) return;
      e.preventDefault();
      e.stopPropagation();
      this.cancelCreateDrag();
      // The release that follows is still the drag's; the drag mixin swallows its click.
      this.swallowClick = true;
      this.escaped = true;
    };
    this.draftListeners = [
      ["pointerdown", (e) => this.draftPointerDown(e)],
      ["pointermove", (e) => this.draftPointerMove(e)],
      ["pointerup", (e) => this.draftPointerUp(e)],
      ["pointercancel", () => this.cancelCreateDrag()],
      ["contextmenu", () => this.cancelCreateDrag()],
      ["lostpointercapture", () => this.cancelCreateDrag()],
    ];
    for (const [name, listener] of this.draftListeners) this.el.addEventListener(name, listener);
    this.handleEvent("calendar:draft-cleared", ({ draft }) => this.draftCleared(draft));
  },

  destroyDraft() {
    for (const [name, listener] of this.draftListeners || []) this.el.removeEventListener(name, listener);
    document.removeEventListener("keydown", this.createEscape);
    this.createDrag?.element.remove();
    this.createPress = null;
    this.createDrag = null;
  },

  // Whether something is open over the grid that a press should close first.
  hasLayer() {
    return !!(this.list || this.explainer || this.draft || document.getElementById("calendar-preview"));
  },

  // The day column under `target` when it is an empty part of one.
  emptyColumn(target) {
    const column = target?.closest?.(".cal-col");
    if (!column || !this.el.contains(column) || target.closest(NOT_EMPTY)) return null;
    return column;
  },

  defaultCalendar() {
    const { default_calendar: chosen, calendars } = this.settings;
    return chosen ?? calendars?.[0]?.key ?? null;
  },

  draftPointerDown(e) {
    // A press whose release was never seen must not start a drag later.
    this.endCreateDrag();
    this.pressHadLayer = this.hasLayer();
    if (e.button !== 0 || e.pointerType === "touch" || !this.settings || this.drag || this.pressHadLayer) return;
    if (!this.emptyColumn(e.target)) return;
    const geometry = this.gridGeometry();
    const slot = slotAt({ x: e.clientX, y: e.clientY }, geometry);
    if (slot.minute < geometry.scale.firstMinute) return;
    this.createPress = { x: e.clientX, y: e.clientY, pointerId: e.pointerId, slot };
  },

  draftPointerMove(e) {
    if (!this.createPress || !samePointer(this.createPress, e)) return;
    if (e.buttons === 0) {
      this.cancelCreateDrag();
      return;
    }
    if (!this.createDrag) {
      if (Math.hypot(e.clientX - this.createPress.x, e.clientY - this.createPress.y) < DRAG_THRESHOLD) return;
      if (!this.startCreateDrag()) return;
    }
    e.preventDefault();
    const geometry = this.gridGeometry();
    const { day, minute } = this.createPress.slot;
    this.createDrag.range = createRange(day, minute, slotAt({ x: e.clientX, y: e.clientY }, geometry).minute, geometry.scale.firstMinute);
    this.drawCreateDrag(geometry);
  },

  // True when the span block could be put in its column.
  startCreateDrag() {
    this.cancelMove?.({ announce: false });
    this.closeList();
    const iso = isoFromDay(this.createPress.slot.day);
    const column = this.el.querySelector(`.cal-col[data-day="${iso}"]`);
    if (!column) {
      this.createPress = null;
      return false;
    }
    const element = document.createElement("div");
    element.className = "cal-ev is-draft is-drawing";
    element.setAttribute("aria-hidden", "true");
    element.innerHTML = `<span class="cal-ev-title"></span><span class="cal-ev-time"></span>`;
    element.querySelector(".cal-ev-title").textContent = this.strings.new_event ?? "";
    column.appendChild(element);
    if (this.createPress.pointerId !== undefined) this.el.setPointerCapture?.(this.createPress.pointerId);
    document.addEventListener("keydown", this.createEscape);
    this.createDrag = { element, column, range: null };
    return true;
  },

  drawCreateDrag(geometry) {
    const { element, column, range } = this.createDrag;
    const box = previewBox(range, geometry.scale);
    const tf = this.settings.time_format;
    element.style.top = `${box.top}px`;
    element.style.height = `${box.height}px`;
    element.style.setProperty("--l", "1px");
    element.style.setProperty("--w", `${Math.max((column.clientWidth || geometry.colWidth) - 9, 12)}px`);
    element.querySelector(".cal-ev-time").textContent = `${formatMinutes(range.startMin % MINUTES_PER_DAY, tf)}–${formatMinutes(range.endMin % MINUTES_PER_DAY, tf)}`;
  },

  draftPointerUp(e) {
    if (!this.createPress || !samePointer(this.createPress, e)) return;
    const drag = this.createDrag;
    this.endCreateDrag();
    // A press without a drag is a click; handleClick drops the draft.
    if (!drag?.range) return;
    this.swallowNextClick();
    this.startDraft(draftFromRange(newDraftId(), drag.range, this.defaultCalendar()));
  },

  endCreateDrag() {
    this.createDrag?.element.remove();
    this.createPress = null;
    this.createDrag = null;
    document.removeEventListener("keydown", this.createEscape);
  },

  // True when a span was being drawn.
  cancelCreateDrag() {
    const wasDrawing = !!this.createDrag;
    this.endCreateDrag();
    if (wasDrawing) this.render();
    return wasDrawing;
  },

  // A click on the grid that no event, chip or control took. True when it
  // was a click on an empty slot: it drops a draft there, or, when the press
  // found something open over the grid, only closed that.
  slotClick(e) {
    const hadLayer = this.pressHadLayer || !!this.list || !!this.draft;
    this.pressHadLayer = false;
    if (!this.settings || !this.emptyColumn(e.target)) return false;
    if (hadLayer) {
      this.closeList();
      this.discardDraft();
      return true;
    }
    const geometry = this.gridGeometry();
    const slot = slotAt({ x: e.clientX, y: e.clientY }, geometry);
    if (slot.minute < geometry.scale.firstMinute) return false;
    this.startDraft(draftFromSlot(newDraftId(), slot, this.defaultCalendar(), geometry.scale.firstMinute));
    return true;
  },

  startDraft(draft) {
    this.cancelMove?.({ announce: false });
    this.closeList();
    this.draft = this.initialDraft ? this.initialDraft(draft) : draft;
    this.render();
    this.openQuickCreate?.();
  },

  // Drops the draft being edited (and its popover). A draft being saved
  // stays: the server is already writing it.
  discardDraft() {
    if (!this.draft || this.draft.status === "saving") return;
    this.closeQuickCreate?.();
    this.draft = null;
    this.render();
  },

  // The draft leaves quick create, saved ("created") or handed to the side
  // panel ("panel"). When the server's copy is already cached it takes over
  // now; otherwise ours is drawn until the next payload.
  handOver(status) {
    const draft = this.draft;
    if (!draft) return;
    this.draft = null;
    if (!this.cache.events.has(`draft-${draft.id}`)) this.handed.set(draft.id, { ...draft, status });
    this.render();
  },

  // An accepted opening leaves quick create but stays drawn until the
  // bookable layer's next push, which carries what it opened; an events
  // payload, which never does, leaves it alone.
  holdOpening(draft) {
    this.draft = null;
    if (draft) this.handed.set(draft.id, { ...draft, status: "created", awaitsLayer: true });
    this.render();
  },

  // A payload arrived: the server's state now includes every draft handed to
  // it, bar the openings still waiting for the bookable layer.
  settleDrafts() {
    for (const [id, draft] of this.handed) if (!draft.awaitsLayer) this.handed.delete(id);
  },

  // The bookable layer arrived: the openings it answers are drawn by it now.
  settleOpenings() {
    for (const [id, draft] of this.handed) if (draft.awaitsLayer) this.handed.delete(id);
  },

  draftCleared(id) {
    if (!this.handed.delete(id)) return;
    this.render();
  },

  // The cached events with our drafts drawn over any server copy of them.
  withDraft(events) {
    const local = [...this.handed.values(), ...(this.draft ? [this.draft] : [])];
    if (!local.length) return events;
    const ids = new Set(local.map((draft) => `draft-${draft.id}`));
    const calendars = this.settings.calendars || [];
    const meetingTypes = this.settings.meeting_types || [];
    const drawn = (draft) => normaliseEvent({ ...draftEvent(draft, calendars), ...openingLook(draft, meetingTypes, this.strings) });
    return [...events.filter((event) => !ids.has(event.id)), ...local.map(drawn)];
  },
};
