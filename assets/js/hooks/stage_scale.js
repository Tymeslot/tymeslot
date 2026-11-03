/**
 * Stage scale: fits the onboarding stage's page miniature to its frame.
 *
 * The theme miniatures are designed at 400px wide. This hook sets
 * `--stage-scale` on its element so the miniature fills the frame's width,
 * up to 1.6x from `lg` (1024px) and never past its own size below, and sets
 * the element's height to the scaled height of the miniature, because
 * `transform: scale` changes how big it looks but not the room it takes:
 * without that, what follows the stage on a phone would slide under it.
 *
 * It refits when the frame or the miniature changes size, when the viewport
 * crosses `lg`, and after every LiveView update (a new step draws a page of
 * a different height). The element is rendered with
 * `JS.ignore_attributes(["style"])`, so a patch never wipes what it sets.
 */

const DESIGN_WIDTH = 400
const WIDE_QUERY = "(min-width: 1024px)"

/**
 * The scale that makes a 400px miniature fill `width`, within the cap for
 * the screen size; 1 while the frame has no width yet (a hidden modal).
 *
 * @param {number} width the frame's inner width in pixels
 * @param {boolean} wide whether the viewport is `lg` or wider
 * @returns {number}
 */
export function stageScale(width, wide) {
  if (!(width > 0)) return 1
  const cap = wide ? 1.6 : 1
  return Math.min(cap, width / DESIGN_WIDTH)
}

export const StageScale = {
  mounted() {
    this.media = window.matchMedia(WIDE_QUERY)
    this.onMediaChange = () => this.fit()
    this.media.addEventListener("change", this.onMediaChange)

    if (typeof ResizeObserver !== "undefined") {
      // Fitting changes this element's height, which the observer reports
      // again; refitting in the next frame rather than inside the callback
      // keeps that from looping (browsers report a loop as a page error).
      this.resizeObserver = new ResizeObserver(() => this.scheduleFit())
      this.resizeObserver.observe(this.el)
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

  fit() {
    if (!this.inner) this.inner = this.el.firstElementChild
    if (!this.inner) return

    const scale = stageScale(this.el.clientWidth, this.media.matches)
    const height = `${this.inner.offsetHeight * scale}px`

    // Only writes what changed, so a refit that changes nothing does not
    // set the observer off again.
    if (this.el.style.getPropertyValue("--stage-scale") !== String(scale)) {
      this.el.style.setProperty("--stage-scale", String(scale))
    }
    if (this.el.style.height !== height) this.el.style.height = height
  }
}
