/**
 * Sticky nav clearance: keeps a focused field clear of a nav row stuck to
 * the bottom of the screen.
 *
 * Below `lg` the onboarding's Back and Continue row sticks to the bottom of
 * the screen. A browser scrolls a focused field into view only when it is
 * off screen, and WebKit ignores `scroll-padding` when it does, so a field
 * that is on screen but under the row stays hidden behind it. On focus this
 * scrolls the page by just enough to bring the field above the row. While
 * the row is not stuck (from `lg`), it never overlaps a field and nothing
 * moves.
 */

const GAP = 16

/**
 * How far to scroll down so a field ends `GAP` pixels above the nav; 0 when
 * the field already clears it.
 *
 * @param {{top: number, bottom: number}} field the focused field's box
 * @param {{top: number, bottom: number}} nav the nav row's box
 * @returns {number}
 */
export function clearanceOffset(field, nav) {
  const overlaps = field.bottom > nav.top && field.top < nav.bottom
  return overlaps ? field.bottom - nav.top + GAP : 0
}

export const StickyNavClearance = {
  mounted() {
    this.onFocusIn = (event) => this.clear(event.target)
    document.addEventListener("focusin", this.onFocusIn)
  },

  destroyed() {
    document.removeEventListener("focusin", this.onFocusIn)
  },

  clear(target) {
    if (!(target instanceof HTMLElement) || this.el.contains(target)) return
    if (!target.matches("input, select, textarea")) return
    if (getComputedStyle(this.el).position !== "sticky") return

    const offset = clearanceOffset(
      target.getBoundingClientRect(),
      this.el.getBoundingClientRect()
    )

    if (offset > 0) window.scrollBy({ top: offset, behavior: "instant" })
  }
}
