/**
 * Tests for the `ChartReadout` hook, the arrow-key focus through a chart's
 * per-bar readouts.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { ChartReadout } from '../hooks/chart_readout'

describe('ChartReadout', () => {
  let root, bars

  beforeEach(() => {
    document.body.innerHTML = `
      <div id="chart">
        <span data-readout-bar tabindex="0"></span>
        <span data-readout-bar tabindex="-1"></span>
        <span data-readout-bar tabindex="-1"></span>
      </div>`
    root = document.getElementById('chart')
    bars = Array.from(root.querySelectorAll('[data-readout-bar]'))
    Object.assign(Object.create(ChartReadout), { el: root }).mounted()
  })

  function press(key, from) {
    from.focus()
    const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true })
    from.dispatchEvent(event)
    return event
  }

  it('moves focus and the single tab stop with the arrow keys', () => {
    const event = press('ArrowRight', bars[0])

    expect(event.defaultPrevented).toBe(true)
    expect(document.activeElement).toBe(bars[1])
    expect(bars.map((bar) => bar.getAttribute('tabindex'))).toEqual(['-1', '0', '-1'])
  })

  it('stops at the ends and jumps with Home and End', () => {
    press('ArrowLeft', bars[0])
    expect(document.activeElement).toBe(bars[0])

    press('End', bars[0])
    expect(document.activeElement).toBe(bars[2])

    press('Home', bars[2])
    expect(document.activeElement).toBe(bars[0])
  })

  it('leaves other keys alone', () => {
    expect(press('Tab', bars[0]).defaultPrevented).toBe(false)
  })
})
