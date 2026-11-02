/**
 * Clamped text: offers "Show more" only when a cut text actually runs past
 * its cut.
 *
 * `Shared.Components.MeetingTypeDescription` draws a meeting type's
 * description cut to a few lines (CSS `line-clamp`) with a toggle that shows
 * the rest. Whether the cut hides anything depends on the card's width, the
 * font and the language, which only the browser knows, so this hook measures
 * the text and marks the root `data-overflowing` while it runs past the cut;
 * the stylesheet shows the toggle only then, or while the text is expanded
 * (`.is-expanded`, set by the toggle's own `JS` command, so the toggle stays
 * to fold it again).
 *
 * The mark is re-measured on every patch (a patch drops an attribute the
 * server did not render) and whenever the text's box changes size: a resize,
 * a rotation, or a web font arriving.
 */

// A pixel of slack: zoomed and high-density screens report fractional heights.
const SLACK = 1

/**
 * Whether a clamped element hides part of its content.
 *
 * @param {{scrollHeight: number, clientHeight: number}} el
 * @returns {boolean}
 */
export function overflows({ scrollHeight, clientHeight }) {
  return scrollHeight > clientHeight + SLACK
}

export const ClampedText = {
  mounted() {
    this.measure()

    if (typeof ResizeObserver === "function") {
      this.observer = new ResizeObserver(() => this.measure())
      this.observer.observe(this.text())
    }
  },

  updated() {
    this.measure()
  },

  destroyed() {
    this.observer?.disconnect()
  },

  text() {
    return this.el.querySelector("[data-clamped-text]") || this.el
  },

  measure() {
    // Expanded text is not clamped, so it never measures as overflowing;
    // the stylesheet keeps the toggle while `.is-expanded` is set.
    if (this.el.classList.contains("is-expanded")) return

    this.el.toggleAttribute("data-overflowing", overflows(this.text()))
  }
}
