/**
 * Swipe and pinch for the CalendarCanvas hook (mixed into it).
 *
 * A finger moving sideways over the time grid, or anywhere over the month,
 * pulls the drawn period after it (`swipeOffset`, written on the canvas's
 * children as --cal-swipe-x); let go after a swipe (`swipeStep`) and the next
 * or previous period draws at once from the cache, while `calendar:goto`
 * tells the server, which patches the URL. A swipe that falls short, or
 * turns into a scroll, springs back. Two fingers over the time grid pinch the
 * hour height (`pinchedHour`, then `zoomTo` from zoom.js), keeping the hour
 * between them in place; a third finger stops both.
 *
 * Both follow the pointer type, not the width: a touch tablet in desktop
 * chrome gets them too. Neither starts while a long-press has picked up an
 * event (`this.drag`), or while a sheet, a popover or the preview is open.
 * While either is under way, touchmove is cancelled so the page neither
 * scrolls nor zooms with it.
 */
import { PRESS_SLOP, SWIPE_RATIO, pinchDistance, pinchedHour, swipeOffset, swipeStep } from "../../calendar/gestures.js";
import { isTimeGrid, shiftPeriod } from "../../calendar/time.js";

export const GesturesMixin = {
  mountGestures() {
    this.fingers = new Map();
    this.swipe = null;
    this.pinch = null;
    this.gestureListeners = [
      ["pointerdown", (e) => this.gestureDown(e)],
      ["pointermove", (e) => this.gestureMove(e)],
      ["pointerup", (e) => this.gestureUp(e)],
      ["pointercancel", (e) => this.gestureCancel(e)],
    ];
    for (const [name, listener] of this.gestureListeners) this.el.addEventListener(name, listener);
    // Not passive: a pinch or a sideways swipe must not also move the page.
    this.gestureGuard = (e) => {
      if (this.pinch || this.swipe?.active) e.preventDefault();
    };
    this.el.addEventListener("touchmove", this.gestureGuard, { passive: false });
  },

  destroyGestures() {
    for (const [name, listener] of this.gestureListeners || []) this.el.removeEventListener(name, listener);
    this.el.removeEventListener("touchmove", this.gestureGuard);
    this.endSwipe();
    this.fingers?.clear();
    this.endPinch();
  },

  // Hands the fingers to the canvas, so a redraw under them (every pinch step
  // redraws) does not send their lift somewhere else.
  holdPointer(id) {
    try {
      this.el.setPointerCapture?.(id);
    } catch {
      // The pointer is already gone; nothing to hold.
    }
  },

  endPinch() {
    this.pinch = null;
    if (this.pinchFrame) cancelAnimationFrame(this.pinchFrame);
    this.pinchFrame = null;
    this.pinchTarget = null;
  },

  // Something else has the finger or the screen.
  gestureBlocked() {
    return (
      !this.settings ||
      !!this.drag ||
      !!this.quick ||
      this.overlayOpen() ||
      !!document.getElementById("calendar-preview") ||
      document.documentElement.classList.contains("cal-sheet-open")
    );
  },

  swipeable(target) {
    if (this.view === "month") return true;
    return isTimeGrid(this.view) && !!target.closest?.("[data-scroll]");
  },

  gestureDown(e) {
    if (e.pointerType !== "touch") return;
    // A fresh touch starts from nothing: a lift that never arrived must not
    // leave a finger behind that turns every later touch into a pinch.
    if (e.isPrimary) {
      this.fingers.clear();
      this.endPinch();
    }
    this.fingers.set(e.pointerId, { x: e.clientX, y: e.clientY, grid: !!e.target.closest?.("[data-scroll]") });
    if (this.fingers.size === 2) {
      this.endSwipe();
      this.startPinch();
      return;
    }
    if (this.fingers.size > 2) {
      this.endSwipe();
      this.endPinch();
      return;
    }
    if (this.gestureBlocked() || !this.swipeable(e.target)) return;
    this.swipe = { pointerId: e.pointerId, x: e.clientX, y: e.clientY, at: Date.now(), active: false };
  },

  startPinch() {
    if (this.gestureBlocked() || !isTimeGrid(this.view) || !this.el.querySelector(".cal-cols")) return;
    const [a, b] = [...this.fingers.values()];
    if (!a.grid || !b.grid) return;
    this.pinch = { distance: pinchDistance(a, b), hour: this.zoomHour ?? this.hourHeight() };
    for (const id of this.fingers.keys()) this.holdPointer(id);
  },

  gestureMove(e) {
    if (e.pointerType !== "touch" || !this.fingers.has(e.pointerId)) return;
    this.fingers.set(e.pointerId, { ...this.fingers.get(e.pointerId), x: e.clientX, y: e.clientY });
    if (this.pinch) {
      const [a, b] = [...this.fingers.values()];
      // One zoom per frame, however many moves arrive in it.
      this.pinchTarget = { hour: pinchedHour(this.pinch.hour, this.pinch.distance, pinchDistance(a, b)), y: (a.y + b.y) / 2 };
      this.pinchFrame ||= requestAnimationFrame(() => {
        this.pinchFrame = null;
        const target = this.pinchTarget;
        if (this.pinch && target) this.zoomTo(target.hour, target.y);
      });
      return;
    }
    const swipe = this.swipe;
    if (!swipe || swipe.pointerId !== e.pointerId) return;
    // A long-press has made the finger a drag.
    if (this.drag) {
      this.endSwipe();
      return;
    }
    const dx = e.clientX - swipe.x;
    const dy = e.clientY - swipe.y;
    if (!swipe.active) {
      // Up or down first: a scroll, which the browser keeps.
      if (Math.abs(dy) > PRESS_SLOP && Math.abs(dy) >= Math.abs(dx)) {
        this.endSwipe();
        return;
      }
      // Too steep to ever step the period: leave it to the scroll.
      if (Math.abs(dx) <= PRESS_SLOP || Math.abs(dx) < SWIPE_RATIO * Math.abs(dy)) return;
      swipe.active = true;
      this.holdPointer(swipe.pointerId);
    }
    const offset = `${Math.round(swipeOffset(dx, this.el.clientWidth))}px`;
    for (const child of this.el.children) {
      child.classList.add("cal-swiping");
      child.style.setProperty("--cal-swipe-x", offset);
    }
  },

  gestureUp(e) {
    if (e.pointerType !== "touch") return;
    this.fingers.delete(e.pointerId);
    if (this.pinch) {
      if (this.fingers.size < 2) this.endPinch();
      return;
    }
    const swipe = this.swipe;
    if (!swipe || swipe.pointerId !== e.pointerId) return;
    const step = swipe.active && !this.drag ? swipeStep(swipe, { x: e.clientX, y: e.clientY }, Date.now() - swipe.at) : 0;
    this.endSwipe();
    if (!step) return;
    // The lift that ends a swipe is not a tap on what lies under it.
    this.swallowNextClick();
    this.stepPeriod(step);
  },

  gestureCancel(e) {
    this.fingers.delete(e.pointerId);
    if (this.fingers.size < 2) this.endPinch();
    if (this.swipe?.pointerId === e.pointerId) this.endSwipe();
  },

  // The drawn period springs back (after a step the new one is drawn in place).
  endSwipe() {
    this.swipe = null;
    for (const child of this.el.children) {
      if (!child.classList.contains("cal-swiping")) continue;
      child.classList.remove("cal-swiping");
      child.style.removeProperty("--cal-swipe-x");
    }
  },

  // One period on from the one shown, or from the one still pending, as the
  // toolbar's previous and next do; the server patches the URL.
  stepPeriod(direction) {
    const from = this.pending ?? { view: this.view, date: this.date };
    const date = shiftPeriod(from.view, from.date, direction);
    this.navigate({ view: from.view, date });
    this.pushEventTo(this.el, "calendar:goto", { view: from.view, date });
  },
};
