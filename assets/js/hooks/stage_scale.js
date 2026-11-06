/**
 * Stage scale: fits the onboarding stage's page miniature to its frame.
 *
 * The theme miniatures are designed at 400px wide. This hook sets
 * `--stage-scale` on its element so the miniature fills the frame, and sets
 * the element's height to the scaled height of the miniature, because
 * `transform: scale` changes how big it looks but not the room it takes:
 * without that, what follows the stage on a phone would slide under it.
 *
 * From `lg` (1024px) the whole page has to fit: the scale is the smallest of
 * the 1.2 cap, the frame's width over 400px, and the height the stage has
 * left for the page over the page's own height. That height is read off the
 * nearest `[data-stage-fit]` ancestor: its content height, less whatever it
 * holds besides the page (the browser bar, the caption, the gaps between).
 * Below `lg` the page fits the width, never past its own size, and the card
 * cuts it off at the bottom. On a step that highlights part of the page
 * (an element marked `data-stage-focus`, such as the calendar area), the
 * page is shifted up inside the card (`--stage-shift`) so that part is in
 * view; with no such mark the card shows the top of the page. The shift is
 * a jump inside the card, never a scroll of the page around it.
 *
 * It refits when the frame, the stage or the miniature changes size, when
 * the viewport crosses `lg`, and after every LiveView update (a new step
 * draws a page of a different height). The element is rendered with
 * `JS.ignore_attributes(["style"])`, so a patch never wipes what it sets.
 */

const DESIGN_WIDTH = 400
const WIDE_CAP = 1.2
const WIDE_QUERY = "(min-width: 1024px)"

/**
 * The scale for a 400px miniature: it fills `width`, within the cap for the
 * screen size, and, given an `availableHeight`, keeps the whole page within
 * it. 1 while the frame has no width yet (a hidden modal).
 *
 * @param {{width: number, wide: boolean, availableHeight?: number, innerHeight?: number}} fit
 * @returns {number}
 */
export function stageScale({ width, wide, availableHeight = Infinity, innerHeight = 0 }) {
  if (!(width > 0)) return 1

  const cap = wide ? WIDE_CAP : 1
  const byHeight = innerHeight > 0 && availableHeight > 0 ? availableHeight / innerHeight : Infinity
  return Math.min(cap, width / DESIGN_WIDTH, byHeight)
}

/**
 * The height left for the page in a fixed-height box: its content height
 * less the extent of what it holds that is not the page.
 *
 * @param {number} contentHeight the box's height inside its padding
 * @param {Array<{top: number, bottom: number}>} children the boxes of its shown children
 * @param {number} pageHeight the page wrapper's current height
 * @returns {number}
 */
export function heightForPage(contentHeight, children, pageHeight) {
  if (children.length === 0) return Infinity

  const top = Math.min(...children.map((box) => box.top))
  const bottom = Math.max(...children.map((box) => box.bottom))
  return contentHeight - (bottom - top - pageHeight)
}

/**
 * How far to shift the page up inside a card `viewport` pixels tall so the
 * focused region (from `top` to `bottom`, in the scaled page) is in view:
 * enough to show its bottom, never so much that its top is cut, never past
 * the end of the page, and none when it is already in view.
 *
 * @param {{viewport: number, top: number, bottom: number, pageHeight: number, margin?: number}} focus
 * @returns {number}
 */
export function focusShift({ viewport, top, bottom, pageHeight, margin = 12 }) {
  if (!(viewport > 0)) return 0

  const wanted = Math.min(top - margin, bottom + margin - viewport)
  const furthest = Math.max(0, pageHeight - viewport)
  return Math.round(Math.min(furthest, Math.max(0, wanted)))
}

export const StageScale = {
  mounted() {
    this.media = window.matchMedia(WIDE_QUERY)
    this.onMediaChange = () => this.fit()
    this.media.addEventListener("change", this.onMediaChange)
    this.box = this.el.closest("[data-stage-fit]")

    if (typeof ResizeObserver !== "undefined") {
      // Fitting changes this element's height, which the observer reports
      // again; refitting in the next frame rather than inside the callback
      // keeps that from looping (browsers report a loop as a page error).
      this.resizeObserver = new ResizeObserver(() => this.scheduleFit())
      this.resizeObserver.observe(this.el)
      if (this.box) this.resizeObserver.observe(this.box)
      // The phone card: a change in its height moves what the shift shows.
      this.card = this.el.closest(".stage-frame-body")
      if (this.card) this.resizeObserver.observe(this.card)
      this.observeInner()
    }

    this.fit()
  },

  updated() {
    this.observeInner()
    this.fit()
  },

  destroyed() {
    this.media.removeEventListener("change", this.onMediaChange)
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
  },

  scheduleFit() {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      this.fit()
    })
  },

  // The miniature is the element's only child; a patch may replace it.
  observeInner() {
    const inner = this.el.firstElementChild
    if (!inner || inner === this.inner) return

    if (this.resizeObserver) {
      if (this.inner) this.resizeObserver.unobserve(this.inner)
      this.resizeObserver.observe(inner)
    }

    this.inner = inner
  },

  availableHeight() {
    if (!this.box || !this.media.matches) return Infinity

    const style = getComputedStyle(this.box)
    const contentHeight =
      this.box.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom)

    // A child that is not shown has an empty box at the origin, which
    // would stretch the extent to the top of the page.
    const shown = Array.from(this.box.children)
      .map((child) => child.getBoundingClientRect())
      .filter((box) => box.height > 0)

    // A pixel short, so rounding never pushes the page past the frame.
    return heightForPage(contentHeight, shown, this.el.getBoundingClientRect().height) - 1
  },

  fit() {
    if (!this.inner) this.inner = this.el.firstElementChild
    if (!this.inner) return

    const innerHeight = this.inner.offsetHeight
    const scale = stageScale({
      width: this.el.clientWidth,
      wide: this.media.matches,
      availableHeight: this.availableHeight(),
      innerHeight
    })
    const height = `${innerHeight * scale}px`

    // Only writes what changed, so a refit that changes nothing does not
    // set the observer off again.
    if (this.el.style.getPropertyValue("--stage-scale") !== String(scale)) {
      this.el.style.setProperty("--stage-scale", String(scale))
    }
    if (this.el.style.height !== height) this.el.style.height = height

    const shift = `${this.shift(innerHeight * scale)}px`
    if (this.el.style.getPropertyValue("--stage-shift") !== shift) {
      this.el.style.setProperty("--stage-shift", shift)
    }
  },

  // Below lg, inside the stage card only (not the expanded preview): the
  // shift that brings the focused region into view, measured on the page
  // as now scaled.
  shift(pageHeight) {
    const card = this.card || this.el.closest(".stage-frame-body")
    const focus = this.inner.querySelector("[data-stage-focus]")
    if (this.media.matches || !card || !focus) return 0

    const pageTop = this.inner.getBoundingClientRect().top
    const box = focus.getBoundingClientRect()

    return focusShift({
      viewport: card.clientHeight,
      top: box.top - pageTop,
      bottom: box.bottom - pageTop,
      pageHeight
    })
  }
}
