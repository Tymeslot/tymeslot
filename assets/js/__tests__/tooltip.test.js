/**
 * Tests for the tooltip behaviour (tooltip.js) behind `<.tooltip>`.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { installTooltips, isActionable } from '../tooltip'

function pointer(type, target, init = {}) {
  const event = new Event(type, { bubbles: true, cancelable: true })
  event.pointerType = init.pointerType || 'mouse'
  Object.defineProperty(event, 'relatedTarget', { value: init.relatedTarget ?? null })
  target.dispatchEvent(event)
  return event
}

function mount(html) {
  document.body.innerHTML = html
  const anchor = document.querySelector('[data-tooltip]')
  const control = anchor.firstElementChild
  const bubble = anchor.querySelector('[role="tooltip"]')
  bubble.showPopover = vi.fn(() => bubble.setAttribute('data-open', ''))
  bubble.hidePopover = vi.fn(() => bubble.removeAttribute('data-open'))
  bubble.matches = (selector) =>
    selector === ':popover-open' ? bubble.hasAttribute('data-open') : Element.prototype.matches.call(bubble, selector)
  control.matches = (selector) =>
    selector === ':focus-visible' ? true : Element.prototype.matches.call(control, selector)
  return { anchor, control, bubble }
}

const BUTTON = `
  <span data-tooltip>
    <button id="b" type="button">Save</button>
    <span id="b-tip" role="tooltip" popover="manual">Reason</span>
  </span>`

describe('tooltip', () => {
  let uninstall

  beforeEach(() => {
    vi.useFakeTimers()
    uninstall = installTooltips(document)
  })

  afterEach(() => {
    uninstall()
    vi.useRealTimers()
    document.body.innerHTML = ''
  })

  it('opens after the hover delay and closes when the pointer leaves', () => {
    const { control, bubble } = mount(BUTTON)

    pointer('pointerover', control)
    expect(bubble.showPopover).not.toHaveBeenCalled()
    vi.advanceTimersByTime(150)
    expect(bubble.showPopover).toHaveBeenCalledTimes(1)

    pointer('pointerout', control)
    vi.advanceTimersByTime(150)
    expect(bubble.hidePopover).toHaveBeenCalledTimes(1)
  })

  it('opens at once on keyboard focus and closes on blur', () => {
    const { control, bubble } = mount(BUTTON)

    control.dispatchEvent(new FocusEvent('focusin', { bubbles: true }))
    expect(bubble.showPopover).toHaveBeenCalledTimes(1)

    control.dispatchEvent(new FocusEvent('focusout', { bubbles: true }))
    expect(bubble.hidePopover).toHaveBeenCalledTimes(1)
  })

  it('Escape closes the open bubble, swallows the key, and stays closed until left', () => {
    const { control, bubble } = mount(BUTTON)

    control.dispatchEvent(new FocusEvent('focusin', { bubbles: true }))

    const modalEscape = vi.fn()
    window.addEventListener('keydown', modalEscape)
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    window.removeEventListener('keydown', modalEscape)

    expect(bubble.hidePopover).toHaveBeenCalledTimes(1)
    expect(modalEscape).not.toHaveBeenCalled()

    // Hovering the same control again does not reopen it...
    pointer('pointerover', control)
    vi.advanceTimersByTime(150)
    expect(bubble.showPopover).toHaveBeenCalledTimes(1)

    // ...until the control has been left.
    pointer('pointerout', control)
    pointer('pointerover', control)
    vi.advanceTimersByTime(150)
    expect(bubble.showPopover).toHaveBeenCalledTimes(2)
  })

  it('lets Escape through when nothing is open', () => {
    mount(BUTTON)

    const modalEscape = vi.fn()
    window.addEventListener('keydown', modalEscape)
    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true }))
    window.removeEventListener('keydown', modalEscape)

    expect(modalEscape).toHaveBeenCalledTimes(1)
  })

  it('toggles on a tap when the control cannot act', () => {
    const { control, bubble } = mount(`
      <span data-tooltip>
        <button id="b" type="button" aria-disabled="true">Save</button>
        <span id="b-tip" role="tooltip" popover="manual">Reason</span>
      </span>`)

    pointer('pointerdown', control, { pointerType: 'touch' })
    expect(bubble.showPopover).toHaveBeenCalledTimes(1)

    pointer('pointerdown', control, { pointerType: 'touch' })
    expect(bubble.hidePopover).toHaveBeenCalledTimes(1)
  })

  it('shows on a long press when the control can act, and swallows the click', () => {
    const { control, bubble } = mount(BUTTON)

    pointer('pointerdown', control, { pointerType: 'touch' })
    expect(bubble.showPopover).not.toHaveBeenCalled()
    vi.advanceTimersByTime(600)
    expect(bubble.showPopover).toHaveBeenCalledTimes(1)
    pointer('pointerup', control, { pointerType: 'touch' })

    const click = new MouseEvent('click', { bubbles: true, cancelable: true })
    control.dispatchEvent(click)
    expect(click.defaultPrevented).toBe(true)
  })

  it('a quick tap on an acting control lets the click through', () => {
    const { control, bubble } = mount(BUTTON)

    pointer('pointerdown', control, { pointerType: 'touch' })
    vi.advanceTimersByTime(100)
    pointer('pointerup', control, { pointerType: 'touch' })
    vi.advanceTimersByTime(600)

    expect(bubble.showPopover).not.toHaveBeenCalled()
    const click = new MouseEvent('click', { bubbles: true, cancelable: true })
    control.dispatchEvent(click)
    expect(click.defaultPrevented).toBe(false)
  })

  it('classifies whether a control can act', () => {
    expect(isActionable(mount(BUTTON).anchor)).toBe(true)
    expect(isActionable(mount(`
      <span data-tooltip>
        <button aria-disabled="true">x</button><span role="tooltip"></span>
      </span>`).anchor)).toBe(false)
    expect(isActionable(mount(`
      <span data-tooltip>
        <input readonly /><span role="tooltip"></span>
      </span>`).anchor)).toBe(false)
    expect(isActionable(mount(`
      <span data-tooltip>
        <span>badge</span><span role="tooltip"></span>
      </span>`).anchor)).toBe(false)
  })
})
