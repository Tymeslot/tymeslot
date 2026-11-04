/**
 * Sticky nav clearance: keeps a focused field clear of a nav row stuck to
 * the bottom of the screen.
 *
 * Below `lg` the onboarding's Back and Continue row sticks to the bottom of
 * the screen. A browser scrolls a focused field into view only when it is
 * off screen, and then only after `focusin` has fired: WebKit ignores
 * `scroll-padding` and parks the field at the bottom edge, under the row,
 * and Chromium scrolls smoothly, so the field is still on its way when
 * focus lands. A field that is on screen but under the row is not scrolled
 * at all. So on focus this scrolls the page itself, at once, by just enough
 * to bring the field above the row, whether it sits under the row or below
 * the screen: the browser then finds it in view and leaves it there. While
 * the row is not stuck (from `lg`), it never overlaps a field and nothing
 * moves.
 *
 * It also publishes the row's height as `--onboarding-nav-height` on the
 * root element, which the stylesheet's `scroll-padding-bottom` reads, so a
 * scroll the browser makes for any other reason (a fragment, a search hit)
 * keeps clear of the row too, however tall the row grows (the hint line
 * under a disabled Continue adds a second line).
 *
 * A field inside an element marked `data-nav-clearance-box` (a dropdown
 * panel whose list opens under its search field) clears that whole element
 * instead, so the list does not stay behind the row either.
 */

const GAP = 16
const HEIGHT_VAR = "--onboarding-nav-height"

/**
 * How far to scroll down so a field ends `GAP` pixels above the nav; 0 when
 * the field already clears it. A field under the nav or below the screen
 * both end below the nav's top edge.
 *
 * @param {{top: number, bottom: number}} field the focused field's box
 * @param {{top: number, bottom: number}} nav the nav row's box
 * @returns {number}
 */
export function clearanceOffset(field, nav) {
  return field.bottom > nav.top ? field.bottom - nav.top + GAP : 0
}

export const StickyNavClearance = {
  mounted() {
    this.onFocusIn = (event) => this.clear(event.target)
    document.addEventListener("focusin", this.onFocusIn)

    if (typeof ResizeObserver === "function") {
      this.resizeObserver = new ResizeObserver(() => this.publishHeight())
      this.resizeObserver.observe(this.el)
    }
    this.publishHeight()
  },

  destroyed() {
    document.removeEventListener("focusin", this.onFocusIn)
    this.resizeObserver?.disconnect()
    document.documentElement.style.removeProperty(HEIGHT_VAR)
  },

  publishHeight() {
    const height = this.el.getBoundingClientRect().height
    document.documentElement.style.setProperty(HEIGHT_VAR, `${Math.ceil(height)}px`)
  },

  clear(target) {
    if (!(target instanceof HTMLElement) || this.el.contains(target)) return
    if (!target.matches("input, select, textarea")) return
    if (getComputedStyle(this.el).position !== "sticky") return

    const box = target.closest("[data-nav-clearance-box]") || target
    const offset = clearanceOffset(
      box.getBoundingClientRect(),
      this.el.getBoundingClientRect()
    )

    if (offset > 0) window.scrollBy({ top: offset, behavior: "instant" })
  }
}
