/**
 * Roving focus for a chart's per-bar readouts (`[data-readout-bar]`).
 *
 * The chart is a single Tab stop: the arrow keys, Home and End move between
 * bars and the bar under focus carries the tabindex. The bars show their value
 * through `<.tooltip>`, so this hook only moves the focus.
 */

const KEYS = { ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1 }

export const ChartReadout = {
  mounted() {
    this.handleKeydown = (event) => {
      const bars = Array.from(this.el.querySelectorAll('[data-readout-bar]'))
      const current = bars.indexOf(event.target)
      if (current < 0) return

      let next
      if (event.key === 'Home') next = 0
      else if (event.key === 'End') next = bars.length - 1
      else if (KEYS[event.key]) next = Math.min(bars.length - 1, Math.max(0, current + KEYS[event.key]))
      else return

      event.preventDefault()
      if (next === current) return

      bars.forEach((bar, index) => bar.setAttribute('tabindex', index === next ? '0' : '-1'))
      bars[next].focus()
    }

    this.el.addEventListener('keydown', this.handleKeydown)
  },

  destroyed() {
    this.el.removeEventListener('keydown', this.handleKeydown)
  },
}
