// calendar_drag.js
// LiveView JS hooks for calendar grid interactions.
// - CalendarDrag: drag-and-drop event rescheduling
// - CalendarResize: drag-resize event end time
// - CalendarCreate: click-drag to create new events (used in T-63)

const HOUR_HEIGHT_PX = 64  // 4rem at 16px base (h-16 in Tailwind)
const SNAP_MINUTES = 15

function snapToGrid(minutes) {
  return Math.round(minutes / SNAP_MINUTES) * SNAP_MINUTES
}

function minutesFromY(y) {
  return (y / HOUR_HEIGHT_PX) * 60
}

export const CalendarDrag = {
  mounted() {
    this._dragging = null

    this._onMouseDown = this._handleMouseDown.bind(this)
    this._onMouseMove = this._handleMouseMove.bind(this)
    this._onMouseUp = this._handleMouseUp.bind(this)

    this.el.addEventListener('mousedown', this._onMouseDown)
    document.addEventListener('mousemove', this._onMouseMove)
    document.addEventListener('mouseup', this._onMouseUp)

    // Scroll to 1 hour before the current time so appointments near now are visible
    const topRem = parseFloat(this.el.dataset.currentTopRem)
    if (!isNaN(topRem)) {
      const remInPx = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
      this.el.scrollTop = Math.max(0, topRem * remInPx - HOUR_HEIGHT_PX)
    }
  },

  destroyed() {
    this.el.removeEventListener('mousedown', this._onMouseDown)
    document.removeEventListener('mousemove', this._onMouseMove)
    document.removeEventListener('mouseup', this._onMouseUp)
  },

  _handleMouseDown(e) {
    // Only drag from event blocks, not resize handles
    if (e.target.closest('[data-resize-handle]')) return
    const eventEl = e.target.closest('[data-draggable="true"]')
    if (!eventEl) return

    e.preventDefault()

    const rect = eventEl.getBoundingClientRect()

    this._dragging = {
      eventId: eventEl.dataset.eventId,
      eventDate: eventEl.dataset.eventDate,
      startMinutes: parseInt(eventEl.dataset.startMinutes, 10),
      durationMinutes: parseInt(eventEl.dataset.durationMinutes, 10),
      offsetY: e.clientY - rect.top,
      startX: e.clientX,
      startY: e.clientY,
      hasMoved: false,
      clone: null,
      originalEl: eventEl,
      rect,
    }
  },

  _handleMouseMove(e) {
    if (!this._dragging) return
    const d = this._dragging

    if (!d.hasMoved) {
      const dx = e.clientX - d.startX
      const dy = e.clientY - d.startY
      if (Math.sqrt(dx * dx + dy * dy) < 5) return

      // Threshold crossed — now start the visual drag
      d.hasMoved = true
      d.clone = this._createClone(d.originalEl, d.rect)
      document.body.appendChild(d.clone)
      d.originalEl.style.opacity = '0.3'
    }

    d.clone.style.left = `${e.clientX - 30}px`
    d.clone.style.top = `${e.clientY - d.offsetY}px`
  },

  _handleMouseUp(e) {
    if (!this._dragging) return
    const d = this._dragging

    if (d.hasMoved) {
      const colEl = this._findDayColAt(e.clientX, e.clientY)

      if (colEl) {
        const colRect = colEl.getBoundingClientRect()
        const relY = e.clientY - colRect.top - d.offsetY
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

    this._onMouseDown = this._handleMouseDown.bind(this)
    this._onMouseMove = this._handleMouseMove.bind(this)
    this._onMouseUp = this._handleMouseUp.bind(this)

    this.el.addEventListener('mousedown', this._onMouseDown)
    document.addEventListener('mousemove', this._onMouseMove)
    document.addEventListener('mouseup', this._onMouseUp)
  },

  destroyed() {
    this.el.removeEventListener('mousedown', this._onMouseDown)
    document.removeEventListener('mousemove', this._onMouseMove)
    document.removeEventListener('mouseup', this._onMouseUp)
  },

  _handleMouseDown(e) {
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
    }

    eventEl.style.opacity = '0.7'
  },

  _snappedEndFromEvent(e) {
    const r = this._resizing
    const colRect = r.colEl.getBoundingClientRect()
    const relY = e.clientY - colRect.top
    const rawEnd = minutesFromY(relY)
    return Math.max(r.startMinutes + SNAP_MINUTES, snapToGrid(rawEnd))
  },

  _handleMouseMove(e) {
    if (!this._resizing) return
    const snappedEnd = this._snappedEndFromEvent(e)
    const newHeight = ((snappedEnd - this._resizing.startMinutes) / 60) * HOUR_HEIGHT_PX
    this._resizing.eventEl.style.height = `${newHeight}px`
  },

  _handleMouseUp(e) {
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
    r.eventEl.style.height = ''  // Let LiveView re-render with correct height
    this._resizing = null
  }
}

export const CalendarCreate = {
  mounted() {
    this._creating = null
    this._selectionEl = null

    this._onMouseDown = this._handleMouseDown.bind(this)
    this._onMouseMove = this._handleMouseMove.bind(this)
    this._onMouseUp = this._handleMouseUp.bind(this)

    this.el.addEventListener('mousedown', this._onMouseDown)
    document.addEventListener('mousemove', this._onMouseMove)
    document.addEventListener('mouseup', this._onMouseUp)
  },

  destroyed() {
    this.el.removeEventListener('mousedown', this._onMouseDown)
    document.removeEventListener('mousemove', this._onMouseMove)
    document.removeEventListener('mouseup', this._onMouseUp)
    if (this._selectionEl) {
      this._selectionEl.remove()
      this._selectionEl = null
    }
  },

  _handleMouseDown(e) {
    // Ignore clicks on existing events, resize handles, buttons, and non-day-col areas
    if (e.target.closest('[data-draggable="true"]')) return
    if (e.target.closest('[data-resize-handle]')) return
    if (e.target.closest('button')) return

    const colEl = e.target.closest('[data-day-col]')
    if (!colEl) return

    e.preventDefault()

    const colRect = colEl.getBoundingClientRect()
    const relY = e.clientY - colRect.top
    const rawMinutes = minutesFromY(relY)
    const snappedStart = Math.max(0, snapToGrid(rawMinutes))

    this._creating = {
      startDayCol: colEl.dataset.dayCol,
      endDayCol: colEl.dataset.dayCol,
      startMinutes: snappedStart,
      endMinutes: Math.min(24 * 60, snappedStart + 30),
      colEl,
      currentColEl: colEl,
    }

    // Create visual selection overlay
    this._selectionEl = document.createElement('div')
    this._selectionEl.className = 'absolute left-0 right-0 bg-turquoise-200 opacity-60 rounded pointer-events-none z-10 border-2 border-turquoise-400'
    this._selectionEl.style.top = `${(snappedStart / 60) * HOUR_HEIGHT_PX}px`
    this._selectionEl.style.height = `${(30 / 60) * HOUR_HEIGHT_PX}px`
    colEl.appendChild(this._selectionEl)
  },

  _handleMouseMove(e) {
    if (!this._creating || !this._selectionEl) return

    // Check if the cursor has moved to a different day column
    const hoveredCol = this._findDayColAt(e.clientX, e.clientY)
    if (hoveredCol && hoveredCol.dataset.dayCol !== this._creating.currentColEl.dataset.dayCol) {
      // Move the selection overlay to the new column
      this._selectionEl.remove()
      hoveredCol.appendChild(this._selectionEl)
      this._creating.currentColEl = hoveredCol
      this._creating.endDayCol = hoveredCol.dataset.dayCol
    }

    const colRect = this._creating.currentColEl.getBoundingClientRect()
    const relY = e.clientY - colRect.top
    const rawEnd = minutesFromY(relY)

    // When dragging to a different day, allow any end time (even earlier than start)
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
      // On a different day, show selection from top of column to the cursor position
      const heightPx = (snappedEnd / 60) * HOUR_HEIGHT_PX
      this._selectionEl.style.top = '0px'
      this._selectionEl.style.height = `${heightPx}px`
    }
  },

  _handleMouseUp(e) {
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
    // Only set mobile view on initial load, not reconnects
    if (!this.el.dataset.mobileViewSet && window.innerWidth < 768) {
      this.el.dataset.mobileViewSet = "true";
      this.pushEventTo(this.el, "set_mobile_view", {});
    }

    // Swipe navigation
    this._touchStartX = 0;
    this._touchStartY = 0;

    this._onTouchStart = (e) => {
      this._touchStartX = e.touches[0].clientX;
      this._touchStartY = e.touches[0].clientY;
    };

    this._onTouchEnd = (e) => {
      const dx = e.changedTouches[0].clientX - this._touchStartX;
      const dy = e.changedTouches[0].clientY - this._touchStartY;

      // Only count horizontal swipes (more horizontal than vertical, and > 60px)
      if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy)) {
        const direction = dx < 0 ? "next" : "prev";
        this.pushEventTo(this.el, "navigate_swipe", { direction });
      }
    };

    this.el.addEventListener("touchstart", this._onTouchStart, { passive: true });
    this.el.addEventListener("touchend", this._onTouchEnd, { passive: true });
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this._onTouchStart);
    this.el.removeEventListener("touchend", this._onTouchEnd);
  }
};

export default CalendarDrag
