/**
 * Scroll strip: the behaviour behind `tab_bar/1` and `segmented_control/1`.
 *
 * Both render a single row that scrolls sideways when it does not fit, rather
 * than wrapping into a ragged block. This hook does the parts markup cannot:
 *
 *  - Marks which edges have content beyond them, as `data-overflow` set to
 *    `start`, `end` or `both` (removed when everything fits). The component's
 *    classes turn that into a fade on the clipped edge, which is what tells a
 *    reader there is more to scroll to.
 *  - Brings the selected item into view when the selection changes, so a
 *    strip whose current tab sits past the edge does not open showing every
 *    tab but that one. An update that leaves the selection alone leaves the
 *    scroll position alone too, so a reader browsing the row is not pulled
 *    back.
 *  - In a `role="tablist"`, moves between tabs with the arrow keys, Home and
 *    End, selecting the tab it lands on: the keyboard model ARIA expects of a
 *    tablist whose tabs, all but the selected one, are out of the tab order.
 */

const SELECTED = '[aria-selected="true"], [aria-current="page"], [aria-pressed="true"]'

/**
 * Which edges of a scrolling row have content beyond them.
 *
 * @param {{scrollLeft: number, scrollWidth: number, clientWidth: number}} el
 * @returns {"start"|"end"|"both"|null}
 */
export function overflowEdges({ scrollLeft, scrollWidth, clientWidth }) {
  // A pixel of slack: zoomed and high-density screens report fractional widths.
  const start = scrollLeft > 1
  const end = scrollLeft + clientWidth < scrollWidth - 1

  if (start && end) return "both"
  if (start) return "start"
  if (end) return "end"
  return null
}

/**
 * The tab a key press moves to, or null when the key is not a tab key.
 *
 * @param {string} key
 * @param {number} index position of the focused tab
 * @param {number} count number of selectable tabs
 * @returns {number|null}
 */
export function nextTabIndex(key, index, count) {
  if (count === 0) return null

  switch (key) {
    case "ArrowRight":
      return (index + 1) % count
    case "ArrowLeft":
      return (index - 1 + count) % count
    case "Home":
      return 0
    case "End":
      return count - 1
    default:
      return null
  }
}

export const ScrollStrip = {
  mounted() {
    this.onScroll = () => this.markOverflow()
    this.onKeydown = (event) => this.moveFocus(event)

    this.el.addEventListener("scroll", this.onScroll, { passive: true })
    this.el.addEventListener("keydown", this.onKeydown)

    if (typeof ResizeObserver !== "undefined") {
      this.resizeObserver = new ResizeObserver(() => this.markOverflow())
      this.resizeObserver.observe(this.el)
    }

    this.revealSelected()
    this.markOverflow()
  },

  // A LiveView patch drops attributes the server did not render, so the mark
  // is recomputed after every update.
  updated() {
    this.revealSelected()
    this.markOverflow()
  },

  destroyed() {
    this.el.removeEventListener("scroll", this.onScroll)
    this.el.removeEventListener("keydown", this.onKeydown)
    if (this.resizeObserver) this.resizeObserver.disconnect()
  },

  markOverflow() {
    const edges = overflowEdges(this.el)

    if (edges) {
      this.el.dataset.overflow = edges
    } else {
      delete this.el.dataset.overflow
    }
  },

  // Scrolls the row itself, never the page, so opening a view does not jump.
  // Selection is keyed by element id where there is one: a patch may replace
  // the element while the same tab stays selected.
  revealSelected() {
    const selected = this.el.querySelector(SELECTED)
    const key = selected ? selected.id || selected : null
    if (key === this.revealedKey) return

    this.revealedKey = key
    if (!selected) return

    const row = this.el.getBoundingClientRect()
    const item = selected.getBoundingClientRect()

    if (item.left < row.left) {
      this.el.scrollLeft -= row.left - item.left
    } else if (item.right > row.right) {
      this.el.scrollLeft += item.right - row.right
    }
  },

  moveFocus(event) {
    if (this.el.getAttribute("role") !== "tablist") return

    const tabs = Array.from(this.el.querySelectorAll('[role="tab"]:not([disabled])'))
    const index = tabs.indexOf(document.activeElement)
    if (index === -1) return

    const next = nextTabIndex(event.key, index, tabs.length)
    if (next === null) return

    event.preventDefault()
    tabs[next].focus()
    if (next !== index) tabs[next].click()
  }
}
