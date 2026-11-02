/**
 * Week grid scroll: keeps the day that matters in view in a narrow week grid.
 *
 * Below 40rem the shared `WeekGrid` shows three days (one below 20rem) and
 * scrolls sideways through the rest, snapping to a day. The grid names the
 * day to show in `data-reveal-date` on `.week-grid__days`: the chosen time's
 * day, else today, else the first day with times (`WeekGrid`'s
 * `reveal_date/2`). This hook scrolls that day's column into view, as little
 * as it takes: a column already wholly in view leaves the row where it is.
 *
 *  - It scrolls the row itself (`scrollLeft`), never the page, so a framed
 *    booking page never moves its frame and the auto-resize is untouched.
 *  - It lands on a column's start (`offsetLeft`), which is where the
 *    mandatory snap would pull any other position back to.
 *  - It moves only when the day to show changes: a new week, or a time
 *    chosen on another day. A patch that leaves it alone (a refetch of the
 *    week on show, the loading state) leaves a visitor browsing the row
 *    where they are.
 *  - Its first placement is instant; a later one glides, unless the visitor
 *    asks for reduced motion.
 *
 * A wide grid shows every day, so there is nothing to scroll and it does
 * nothing.
 */

// A pixel of slack: zoomed and high-density screens report fractional widths.
const SLACK = 1

/**
 * Where to scroll a row of day columns so the column at `index` is wholly in
 * view: the start of a column, or null when it is in view already.
 *
 * Scrolling back puts the column at the start of the view; scrolling on puts
 * it at the end, by starting the view at the first column from which it fits.
 *
 * @param {{scrollLeft: number, clientWidth: number}} row
 * @param {Array<{offsetLeft: number, offsetWidth: number}>} columns in order
 * @param {number} index the column to show
 * @returns {number|null}
 */
export function revealLeft({ scrollLeft, clientWidth }, columns, index) {
  const column = columns[index]
  if (!column) return null

  const start = column.offsetLeft
  const end = column.offsetLeft + column.offsetWidth

  if (start < scrollLeft - SLACK) return start
  if (end <= scrollLeft + clientWidth + SLACK) return null

  // A column wider than the row fits from nowhere: then it starts the view.
  const first = columns
    .slice(0, index + 1)
    .find((candidate) => candidate.offsetLeft >= end - clientWidth - SLACK)

  return (first || column).offsetLeft
}

function prefersReducedMotion() {
  return (
    typeof window.matchMedia === "function" &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches
  )
}

export const WeekGridScroll = {
  mounted() {
    this.reveal(false)
  },

  updated() {
    this.reveal(true)
  },

  reveal(animate) {
    const date = this.el.dataset.revealDate || null
    if (date === this.revealedDate) return

    this.revealedDate = date
    if (!date) return

    // The row is positioned, so each column's offsetLeft is measured from it.
    const columns = Array.from(this.el.children).filter((child) =>
      child.classList.contains("week-grid__day")
    )
    const index = columns.findIndex((column) => column.dataset.date === date)
    const left = revealLeft(this.el, columns, index)
    if (left === null) return

    if (animate && !prefersReducedMotion() && typeof this.el.scrollTo === "function") {
      this.el.scrollTo({ left, behavior: "smooth" })
    } else {
      this.el.scrollLeft = left
    }
  }
}
