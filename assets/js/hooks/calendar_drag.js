// calendar_drag.js
// LiveView JS hooks for calendar grid interactions.
// - CalendarDrag: drag-and-drop event rescheduling (mouse + touch)
// - CalendarResize: drag-resize event end time (mouse + touch)
// - CalendarCreate: click-drag to create new events (mouse + touch)
// - CalendarMobile: mobile viewport detection and swipe navigation

const HOUR_HEIGHT_PX = 64  // 4rem at 16px base (h-16 in Tailwind)
const SNAP_MINUTES = 15
const TOUCH_HOLD_MS = 200       // long-press threshold before a touch becomes a drag
const DRAG_THRESHOLD_PX = 5     // pointer movement before drag starts (mouse)

export function snapToGrid(minutes) {
  return Math.round(minutes / SNAP_MINUTES) * SNAP_MINUTES
}

export function minutesFromY(y) {
  return (y / HOUR_HEIGHT_PX) * 60
}

// Returns {x, y} for mouse or touch events.
export function pointerXY(e) {
  if (e.touches && e.touches[0]) return { x: e.touches[0].clientX, y: e.touches[0].clientY }
  if (e.changedTouches && e.changedTouches[0]) {
    return { x: e.changedTouches[0].clientX, y: e.changedTouches[0].clientY }
  }
  return { x: e.clientX, y: e.clientY }
}

export const CalendarDrag = {
  mounted() {
    this._dragging = null

    this._onPointerDown = this._handlePointerDown.bind(this)
    this._onPointerMove = this._handlePointerMove.bind(this)
    this._onPointerUp = this._handlePointerUp.bind(this)
    this._onScroll = this._handleScroll.bind(this)

    // Mouse
    this.el.addEventListener('mousedown', this._onPointerDown)
    document.addEventListener('mousemove', this._onPointerMove)
    document.addEventListener('mouseup', this._onPointerUp)

    // Touch
    this.el.addEventListener('touchstart', this._onPointerDown, { passive: false })
    document.addEventListener('touchmove', this._onPointerMove, { passive: false })
    document.addEventListener('touchend', this._onPointerUp)
    document.addEventListener('touchcancel', this._onPointerUp)

    // Track scroll position to toggle "jump to now" pill visibility.
    this.el.addEventListener('scroll', this._onScroll, { passive: true })

    this._scrollToCurrentTime()
    this._onScrollToCurrent = () => this._scrollToCurrentTime()
    this.el.addEventListener('calendar:scroll-to-current', this._onScrollToCurrent)

    // Initial pill visibility check after layout settles.
    requestAnimationFrame(() => this._updateJumpToNowVisibility())
  },

  updated() {
    // Data attributes may change when the user navigates periods — recheck.
    this._updateJumpToNowVisibility()
  },

  destroyed() {
    this.el.removeEventListener('mousedown', this._onPointerDown)
    document.removeEventListener('mousemove', this._onPointerMove)
    document.removeEventListener('mouseup', this._onPointerUp)
    this.el.removeEventListener('touchstart', this._onPointerDown)
    document.removeEventListener('touchmove', this._onPointerMove)
    document.removeEventListener('touchend', this._onPointerUp)
    document.removeEventListener('touchcancel', this._onPointerUp)
    this.el.removeEventListener('scroll', this._onScroll)
    this.el.removeEventListener('calendar:scroll-to-current', this._onScrollToCurrent)
    this._clearTouchHold()
  },

  _scrollToCurrentTime() {
    const topRem = parseFloat(this.el.dataset.currentTopRem)
    if (isNaN(topRem)) return
    const remInPx = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
    this.el.scrollTop = Math.max(0, topRem * remInPx - HOUR_HEIGHT_PX)
    requestAnimationFrame(() => this._updateJumpToNowVisibility())
  },

  _handleScroll() {
    this._updateJumpToNowVisibility()
  },

  _updateJumpToNowVisibility() {
    const pill = document.getElementById('calendar-jump-to-now')
    if (!pill) return

    // Only show pill when the current time indicator falls within the visible period
    // (i.e. today is in the visible date range). The server-rendered `data-show-now`
    // attribute reflects this.
    if (this.el.dataset.showNow !== 'true') {
      pill.classList.add('hidden')
      return
    }

    const topRem = parseFloat(this.el.dataset.currentTopRem)
    if (isNaN(topRem)) {
      pill.classList.add('hidden')
      return
    }

    const remInPx = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
    const markerTop = topRem * remInPx
    const viewTop = this.el.scrollTop
    const viewBottom = viewTop + this.el.clientHeight
    const offscreen = markerTop < viewTop + 32 || markerTop > viewBottom - 32
    pill.classList.toggle('hidden', !offscreen)
  },

  _clearTouchHold() {
    if (this._touchHoldTimer) {
      clearTimeout(this._touchHoldTimer)
      this._touchHoldTimer = null
    }
  },

  _handlePointerDown(e) {
    // Only drag from event blocks, not resize handles
    if (e.target.closest('[data-resize-handle]')) return
    const eventEl = e.target.closest('[data-draggable="true"]')
    if (!eventEl) return

    const isTouch = e.type === 'touchstart'
    const { x, y } = pointerXY(e)
    const rect = eventEl.getBoundingClientRect()

    const dragState = {
      eventId: eventEl.dataset.eventId,
      eventDate: eventEl.dataset.eventDate,
      startMinutes: parseInt(eventEl.dataset.startMinutes, 10),
      durationMinutes: parseInt(eventEl.dataset.durationMinutes, 10),
      offsetY: y - rect.top,
      startX: x,
      startY: y,
      hasMoved: false,
      clone: null,
      originalEl: eventEl,
      rect,
      isTouch,
      armed: !isTouch,  // mouse: immediately armed; touch: wait for long-press
    }

    if (isTouch) {
      this._touchHoldTimer = setTimeout(() => {
        this._touchHoldTimer = null
        dragState.armed = true
      }, TOUCH_HOLD_MS)
    } else {
      e.preventDefault()
    }

    this._dragging = dragState
  },

  _handlePointerMove(e) {
    if (!this._dragging) return
    const d = this._dragging
    const { x, y } = pointerXY(e)

    // Touch: if the finger moves before the hold timer fires, it's a scroll, not a drag.
    if (d.isTouch && !d.armed) {
      const dx = x - d.startX
      const dy = y - d.startY
      if (Math.sqrt(dx * dx + dy * dy) > DRAG_THRESHOLD_PX) {
        this._clearTouchHold()
        this._dragging = null
      }
      return
    }

    if (!d.hasMoved) {
      const dx = x - d.startX
      const dy = y - d.startY
      if (Math.sqrt(dx * dx + dy * dy) < DRAG_THRESHOLD_PX) return

      d.hasMoved = true
      d.clone = this._createClone(d.originalEl, d.rect)
      document.body.appendChild(d.clone)
      d.originalEl.style.opacity = '0.3'
    }

    // Prevent scrolling while dragging on touch devices.
    if (d.isTouch && e.cancelable) e.preventDefault()

    d.clone.style.left = `${x - 30}px`
    d.clone.style.top = `${y - d.offsetY}px`
  },

  _handlePointerUp(e) {
    this._clearTouchHold()
    if (!this._dragging) return
    const d = this._dragging

    if (d.hasMoved) {
      const { x, y } = pointerXY(e)
      const colEl = this._findDayColAt(x, y)

      if (colEl) {
        const colRect = colEl.getBoundingClientRect()
        const relY = y - colRect.top - d.offsetY
        const rawStartMinutes = minutesFromY(relY)
        const snappedStart = Math.max(0, Math.min(23 * 60, snapToGrid(rawStartMinutes)))
        const snappedEnd = Math.min(24 * 60, snappedStart + d.durationMinutes)

        this.pushEventTo(this.el, 'event_dropped', {
          'event-id': d.eventId,
          'new-date': colEl.dataset.dayCol,
          'new-hour': String(Math.floor(snappedStart / 60)),
          'new-minute': String(snappedStart % 60),
          'new-end-hour': String(Math.floor(snappedEnd / 60)),
          'new-end-minute': String(snappedEnd % 60),
        })
      }

      d.clone.remove()
      d.originalEl.style.opacity = ''
    }

    this._dragging = null
  },

  _findDayColAt(x, y) {
    const clone = this._dragging?.clone
    if (clone) clone.style.pointerEvents = 'none'
    const el = document.elementFromPoint(x, y)
    if (clone) clone.style.pointerEvents = ''
    return el?.closest('[data-day-col]') || null
  },

  _createClone(eventEl, rect) {
    const clone = eventEl.cloneNode(true)
    Object.assign(clone.style, {
      position: 'fixed',
      width: `${rect.width}px`,
      height: `${rect.height}px`,
      opacity: '0.85',
      pointerEvents: 'none',
      zIndex: '9999',
      left: `${rect.left}px`,
      top: `${rect.top}px`,
      margin: '0',
    })
    return clone
  }
}

export const CalendarResize = {
  mounted() {
    this._resizing = null

    this._onPointerDown = this._handlePointerDown.bind(this)
    this._onPointerMove = this._handlePointerMove.bind(this)
    this._onPointerUp = this._handlePointerUp.bind(this)

    this.el.addEventListener('mousedown', this._onPointerDown)
    document.addEventListener('mousemove', this._onPointerMove)
    document.addEventListener('mouseup', this._onPointerUp)

    this.el.addEventListener('touchstart', this._onPointerDown, { passive: false })
    document.addEventListener('touchmove', this._onPointerMove, { passive: false })
    document.addEventListener('touchend', this._onPointerUp)
    document.addEventListener('touchcancel', this._onPointerUp)
  },

  destroyed() {
    this.el.removeEventListener('mousedown', this._onPointerDown)
    document.removeEventListener('mousemove', this._onPointerMove)
    document.removeEventListener('mouseup', this._onPointerUp)
    this.el.removeEventListener('touchstart', this._onPointerDown)
    document.removeEventListener('touchmove', this._onPointerMove)
    document.removeEventListener('touchend', this._onPointerUp)
    document.removeEventListener('touchcancel', this._onPointerUp)
  },

  _handlePointerDown(e) {
    const handle = e.target.closest('[data-resize-handle]')
    if (!handle) return

    e.preventDefault()
    e.stopPropagation()

    const eventEl = handle.closest('[data-draggable="true"]')
    if (!eventEl) return

    const colEl = eventEl.closest('[data-day-col]')
    if (!colEl) return

    this._resizing = {
      eventId: eventEl.dataset.eventId,
      eventDate: eventEl.dataset.eventDate,
      startMinutes: parseInt(eventEl.dataset.startMinutes, 10),
      colEl,
      eventEl,
      isTouch: e.type === 'touchstart',
    }

    eventEl.style.opacity = '0.7'
  },

  _snappedEndFromEvent(e) {
    const r = this._resizing
    const { y } = pointerXY(e)
    const colRect = r.colEl.getBoundingClientRect()
    const relY = y - colRect.top
    const rawEnd = minutesFromY(relY)
    return Math.max(r.startMinutes + SNAP_MINUTES, snapToGrid(rawEnd))
  },

  _handlePointerMove(e) {
    if (!this._resizing) return
    if (this._resizing.isTouch && e.cancelable) e.preventDefault()
    const snappedEnd = this._snappedEndFromEvent(e)
    const newHeight = ((snappedEnd - this._resizing.startMinutes) / 60) * HOUR_HEIGHT_PX
    this._resizing.eventEl.style.height = `${newHeight}px`
  },

  _handlePointerUp(e) {
    if (!this._resizing) return
    const r = this._resizing
    const snappedEnd = this._snappedEndFromEvent(e)

    this.pushEventTo(this.el, 'event_resized', {
      'event-id': r.eventId,
      'event-date': r.eventDate,
      'new-end-hour': String(Math.floor(snappedEnd / 60)),
      'new-end-minute': String(snappedEnd % 60),
    })

    r.eventEl.style.opacity = ''
    r.eventEl.style.height = ''
    this._resizing = null
  }
}

export const CalendarCreate = {
  mounted() {
    this._creating = null
    this._selectionEl = null

    this._onPointerDown = this._handlePointerDown.bind(this)
    this._onPointerMove = this._handlePointerMove.bind(this)
    this._onPointerUp = this._handlePointerUp.bind(this)

    this.el.addEventListener('mousedown', this._onPointerDown)
    document.addEventListener('mousemove', this._onPointerMove)
    document.addEventListener('mouseup', this._onPointerUp)

    this.el.addEventListener('touchstart', this._onPointerDown, { passive: false })
    document.addEventListener('touchmove', this._onPointerMove, { passive: false })
    document.addEventListener('touchend', this._onPointerUp)
    document.addEventListener('touchcancel', this._onPointerUp)
  },

  destroyed() {
    this.el.removeEventListener('mousedown', this._onPointerDown)
    document.removeEventListener('mousemove', this._onPointerMove)
    document.removeEventListener('mouseup', this._onPointerUp)
    this.el.removeEventListener('touchstart', this._onPointerDown)
    document.removeEventListener('touchmove', this._onPointerMove)
    document.removeEventListener('touchend', this._onPointerUp)
    document.removeEventListener('touchcancel', this._onPointerUp)
    if (this._selectionEl) {
      this._selectionEl.remove()
      this._selectionEl = null
    }
    this._clearTouchHold()
  },

  _clearTouchHold() {
    if (this._touchHoldTimer) {
      clearTimeout(this._touchHoldTimer)
      this._touchHoldTimer = null
    }
  },

  _handlePointerDown(e) {
    // Ignore clicks on existing events, resize handles, buttons
    if (e.target.closest('[data-draggable="true"]')) return
    if (e.target.closest('[data-resize-handle]')) return
    if (e.target.closest('button')) return

    const colEl = e.target.closest('[data-day-col]')
    if (!colEl) return

    const isTouch = e.type === 'touchstart'
    const { x, y } = pointerXY(e)

    // On touch, require a long-press to distinguish creation from scrolling.
    if (isTouch) {
      const { x: startX, y: startY } = { x, y }
      this._touchHoldTimer = setTimeout(() => {
        this._touchHoldTimer = null
        this._beginCreate(colEl, startX, startY, true)
      }, TOUCH_HOLD_MS)
      // Cancel hold if the finger moves before the timer fires.
      this._pendingTouchStart = { x, y }
      return
    }

    e.preventDefault()
    this._beginCreate(colEl, x, y, false)
  },

  _beginCreate(colEl, x, y, isTouch) {
    const colRect = colEl.getBoundingClientRect()
    const relY = y - colRect.top
    const rawMinutes = minutesFromY(relY)
    const snappedStart = Math.max(0, snapToGrid(rawMinutes))

    this._creating = {
      startDayCol: colEl.dataset.dayCol,
      endDayCol: colEl.dataset.dayCol,
      startMinutes: snappedStart,
      endMinutes: Math.min(24 * 60, snappedStart + 30),
      colEl,
      currentColEl: colEl,
      isTouch,
    }

    this._selectionEl = document.createElement('div')
    this._selectionEl.className = 'absolute left-0 right-0 bg-turquoise-200 opacity-60 rounded-token-sm pointer-events-none z-10 border-2 border-turquoise-400'
    this._selectionEl.style.top = `${(snappedStart / 60) * HOUR_HEIGHT_PX}px`
    this._selectionEl.style.height = `${(30 / 60) * HOUR_HEIGHT_PX}px`
    colEl.appendChild(this._selectionEl)
  },

  _handlePointerMove(e) {
    // Cancel pending long-press if finger moves before timer fires.
    if (this._pendingTouchStart && this._touchHoldTimer) {
      const { x, y } = pointerXY(e)
      const dx = x - this._pendingTouchStart.x
      const dy = y - this._pendingTouchStart.y
      if (Math.sqrt(dx * dx + dy * dy) > DRAG_THRESHOLD_PX) {
        this._clearTouchHold()
        this._pendingTouchStart = null
      }
    }

    if (!this._creating || !this._selectionEl) return
    if (this._creating.isTouch && e.cancelable) e.preventDefault()

    const { x, y } = pointerXY(e)
    const hoveredCol = this._findDayColAt(x, y)
    if (hoveredCol && hoveredCol.dataset.dayCol !== this._creating.currentColEl.dataset.dayCol) {
      this._selectionEl.remove()
      hoveredCol.appendChild(this._selectionEl)
      this._creating.currentColEl = hoveredCol
      this._creating.endDayCol = hoveredCol.dataset.dayCol
    }

    const colRect = this._creating.currentColEl.getBoundingClientRect()
    const relY = y - colRect.top
    const rawEnd = minutesFromY(relY)

    const isSameDay = this._creating.startDayCol === this._creating.endDayCol
    const minEnd = isSameDay ? this._creating.startMinutes + 15 : 15
    const snappedEnd = Math.max(minEnd, snapToGrid(rawEnd))

    this._creating.endMinutes = snappedEnd

    if (isSameDay) {
      const topPx = (this._creating.startMinutes / 60) * HOUR_HEIGHT_PX
      const heightPx = ((snappedEnd - this._creating.startMinutes) / 60) * HOUR_HEIGHT_PX
      this._selectionEl.style.top = `${topPx}px`
      this._selectionEl.style.height = `${heightPx}px`
    } else {
      const heightPx = (snappedEnd / 60) * HOUR_HEIGHT_PX
      this._selectionEl.style.top = '0px'
      this._selectionEl.style.height = `${heightPx}px`
    }
  },

  _handlePointerUp(_e) {
    this._clearTouchHold()
    this._pendingTouchStart = null
    if (!this._creating) return

    const { startMinutes, endMinutes, startDayCol, endDayCol } = this._creating

    if (endMinutes > 0) {
      const payload = {
        'date': startDayCol,
        'start-hour': String(Math.floor(startMinutes / 60)),
        'start-minute': String(startMinutes % 60),
        'end-hour': String(Math.floor(endMinutes / 60)),
        'end-minute': String(endMinutes % 60),
      }

      if (endDayCol !== startDayCol) {
        payload['end-date'] = endDayCol
      }

      this.pushEventTo(this.el, 'show_create_form', payload)
    }

    if (this._selectionEl) {
      this._selectionEl.remove()
      this._selectionEl = null
    }
    this._creating = null
  },

  _findDayColAt(x, y) {
    if (this._selectionEl) this._selectionEl.style.pointerEvents = 'none'
    const el = document.elementFromPoint(x, y)
    if (this._selectionEl) this._selectionEl.style.pointerEvents = ''
    return el?.closest('[data-day-col]') || null
  }
}

export const CalendarMobile = {
  mounted() {
    // Only set responsive view on initial load, not reconnects
    if (!this.el.dataset.mobileViewSet) {
      this.el.dataset.mobileViewSet = "true";
      const w = window.innerWidth;
      if (w < 640) {
        this.pushEventTo(this.el, "set_responsive_view", { viewport: "mobile" });
      } else if (w < 1024) {
        this.pushEventTo(this.el, "set_responsive_view", { viewport: "tablet" });
      }
    }

    this._touchStartX = 0;
    this._touchStartY = 0;
    this._touchStartTime = 0;

    this._onTouchStart = (e) => {
      this._touchStartX = e.touches[0].clientX;
      this._touchStartY = e.touches[0].clientY;
      this._touchStartTime = Date.now();
    };

    this._onTouchEnd = (e) => {
      const dx = e.changedTouches[0].clientX - this._touchStartX;
      const dy = e.changedTouches[0].clientY - this._touchStartY;
      const dt = Date.now() - this._touchStartTime;

      // Horizontal swipe: > 60px, mostly horizontal, fast (< 500ms).
      // The time check prevents slow scrolls from being misread as swipes.
      if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.5 && dt < 500) {
        const direction = dx < 0 ? "next" : "prev";
        this.pushEventTo(this.el, "navigate_swipe", { direction });
      }
    };

    this.el.addEventListener("touchstart", this._onTouchStart, { passive: true });
    this.el.addEventListener("touchend", this._onTouchEnd, { passive: true });

    // Keyboard navigation — global key handling while calendar is mounted.
    this._onKeyDown = (e) => {
      // Enter / Space on a focused role="button" element → synthesize click.
      // We do this even when the target is inside the calendar so events and day cells
      // with role="button" behave like real buttons for keyboard users.
      if ((e.key === 'Enter' || e.key === ' ') && e.target?.getAttribute?.('role') === 'button'
          && !['BUTTON', 'A', 'INPUT', 'TEXTAREA'].includes(e.target.tagName)) {
        e.preventDefault()
        e.target.click()
        return
      }

      if (this._shouldIgnoreKey(e)) return

      let handled = true
      switch (e.key) {
        case 'ArrowLeft':
          this.pushEventTo(this.el, 'prev_period', {})
          break
        case 'ArrowRight':
          this.pushEventTo(this.el, 'next_period', {})
          break
        case 't':
        case 'T':
          this.pushEventTo(this.el, 'today', {})
          document.getElementById('calendar-drag-zone')?.dispatchEvent(new CustomEvent('calendar:scroll-to-current'))
          break
        case 'd':
        case 'D':
          this.pushEventTo(this.el, 'set_view', { view: 'day' })
          break
        case 'w':
        case 'W':
          this.pushEventTo(this.el, 'set_view', { view: 'week' })
          break
        case 'm':
        case 'M':
          this.pushEventTo(this.el, 'set_view', { view: 'month' })
          break
        default:
          handled = false
      }
      if (handled) e.preventDefault()
    }
    document.addEventListener('keydown', this._onKeyDown)
  },

  _shouldIgnoreKey(e) {
    if (e.metaKey || e.ctrlKey || e.altKey) return true
    const t = e.target
    if (!t) return false
    const tag = t.tagName
    if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return true
    if (t.isContentEditable) return true
    // Ignore keys while a modal is open.
    if (document.querySelector('[role="dialog"][aria-modal="true"]')) return true
    return false
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this._onTouchStart);
    this.el.removeEventListener("touchend", this._onTouchEnd);
    document.removeEventListener('keydown', this._onKeyDown);
  }
};

export default CalendarDrag
