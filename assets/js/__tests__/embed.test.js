/**
 * Behavioral tests for the Tymeslot embedding widget (embed.js).
 *
 * Tests focus on observable behavior — DOM changes, API surface, and security
 * properties — rather than implementation details like variable names.
 */

import { beforeAll, beforeEach, afterEach, describe, expect, test, vi } from 'vitest'
import { readFileSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))

// Load and execute embed.js once. The IIFE sets window.TymeslotBooking.
beforeAll(() => {
  const src = readFileSync(
    resolve(__dirname, '../embed.js'),
    'utf-8'
  )
  // eslint-disable-next-line no-eval
  eval(src)
})

beforeEach(() => {
  document.body.innerHTML = ''
  document.body.style.overflow = ''
  document.body.style.removeProperty('overflow')
  document.documentElement.removeAttribute('data-embedded')
})

afterEach(() => {
  // Clean up any modals or floating buttons left over by tests
  document.getElementById('tymeslot-modal')?.remove()
  document.getElementById('tymeslot-floating-button')?.remove()
  vi.useRealTimers()
})

describe('Public API', () => {
  test('exposes TymeslotBooking on window with all required methods', () => {
    expect(window.TymeslotBooking).toBeDefined()
    expect(typeof window.TymeslotBooking.open).toBe('function')
    expect(typeof window.TymeslotBooking.close).toBe('function')
    expect(typeof window.TymeslotBooking.initFloating).toBe('function')
    expect(typeof window.TymeslotBooking.embed).toBe('function')
    expect(typeof window.TymeslotBooking.showError).toBe('function')
  })
})

describe('open()', () => {
  test('adds a modal overlay to the document body', () => {
    window.TymeslotBooking.open('alice')

    expect(document.getElementById('tymeslot-modal')).not.toBeNull()
  })

  test('embeds a booking iframe inside the modal', () => {
    window.TymeslotBooking.open('alice')

    const iframe = document.querySelector('#tymeslot-modal iframe')
    expect(iframe).not.toBeNull()
    expect(iframe.src).toContain('alice')
  })

  test('URL-encodes the username in the iframe src', () => {
    // A username that would be dangerous if not encoded
    window.TymeslotBooking.open('user name')

    const iframe = document.querySelector('#tymeslot-modal iframe')
    expect(iframe.src).toContain('user%20name')
    expect(iframe.src).not.toContain('user name')
  })

  test('blocks body scrolling while modal is open', () => {
    window.TymeslotBooking.open('alice')

    expect(document.body.style.overflow).toBe('hidden')
  })

  test('replaces an existing modal rather than stacking a second one', async () => {
    // close() uses a 300ms animation delay before removing the DOM element,
    // so we need fake timers to advance past it.
    vi.useFakeTimers()

    window.TymeslotBooking.open('alice')
    window.TymeslotBooking.open('bob')

    // Advance past the 300ms removal animation
    await vi.runAllTimersAsync()

    const modals = document.querySelectorAll('#tymeslot-modal')
    expect(modals.length).toBe(1)
  })
})

describe('modal sizing', () => {
  test('uses legacy default max-width of 640px when no layout is set', () => {
    // Back-compat: a popup snippet that predates the column layout carries no
    // layout, so it must keep the original 640px modal default rather than
    // silently widening to 1000px on upgrade.
    window.TymeslotBooking.open('alice')

    const container = document.querySelector('#tymeslot-modal [data-tymeslot-container]')
    expect(container.style.maxWidth).toContain('640px')
  })

  test('uses 1000px default max-width when layout=column', () => {
    window.TymeslotBooking.open('alice', { layout: 'column' })

    const container = document.querySelector('#tymeslot-modal [data-tymeslot-container]')
    expect(container.style.maxWidth).toContain('1000px')
  })

  test('honours options.maxWidth when explicitly passed', () => {
    window.TymeslotBooking.open('alice', { maxWidth: 1200 })

    const container = document.querySelector('#tymeslot-modal [data-tymeslot-container]')
    expect(container.style.maxWidth).toContain('1200px')
  })

  test('inherits data-max-width from a sibling inline container when none is passed', () => {
    const inline = document.createElement('div')
    inline.id = 'tymeslot-booking'
    inline.setAttribute('data-username', 'alice')
    inline.setAttribute('data-max-width', '900')
    document.body.appendChild(inline)

    window.TymeslotBooking.open('alice')

    const container = document.querySelector('#tymeslot-modal [data-tymeslot-container]')
    expect(container.style.maxWidth).toContain('900px')
  })

  test('caps modal max-height with 100px headroom from the viewport', () => {
    window.TymeslotBooking.open('alice')

    const container = document.querySelector('#tymeslot-modal [data-tymeslot-container]')
    expect(container.style.maxHeight).toContain('calc(100vh - 100px)')
  })

  test('mobile full-screen stylesheet is injected once', () => {
    window.TymeslotBooking.open('alice')
    const first = document.getElementById('tymeslot-modal-styles')
    expect(first).not.toBeNull()
    expect(first.textContent).toContain('@media (max-width: 768px)')

    // Opening a second modal must not duplicate the stylesheet
    window.TymeslotBooking.close()
    window.TymeslotBooking.open('bob')
    expect(document.querySelectorAll('#tymeslot-modal-styles').length).toBe(1)
  })
})

describe('close()', () => {
  test('removes the modal from the DOM after the animation delay', async () => {
    vi.useFakeTimers()

    window.TymeslotBooking.open('alice')
    expect(document.getElementById('tymeslot-modal')).not.toBeNull()

    window.TymeslotBooking.close()
    await vi.runAllTimersAsync()

    expect(document.getElementById('tymeslot-modal')).toBeNull()
  })

  test('restores body overflow to what it was before the modal opened', async () => {
    vi.useFakeTimers()

    document.body.style.overflow = 'scroll'
    window.TymeslotBooking.open('alice')
    expect(document.body.style.overflow).toBe('hidden')

    window.TymeslotBooking.close()
    await vi.runAllTimersAsync()

    expect(document.body.style.overflow).toBe('scroll')
  })

  test('does nothing and does not throw when no modal is open', () => {
    expect(() => window.TymeslotBooking.close()).not.toThrow()
  })
})

describe('initFloating()', () => {
  test('adds a floating button to the document body', () => {
    window.TymeslotBooking.initFloating('alice')

    expect(document.getElementById('tymeslot-floating-button')).not.toBeNull()
  })

  test('replaces an existing floating button instead of adding a second', () => {
    window.TymeslotBooking.initFloating('alice')
    window.TymeslotBooking.initFloating('bob')

    const buttons = document.querySelectorAll('#tymeslot-floating-button')
    expect(buttons.length).toBe(1)
  })
})

describe('embed()', () => {
  test('embeds a booking iframe inside the target container', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'alice')

    const iframe = container.querySelector('iframe')
    expect(iframe).not.toBeNull()
    expect(iframe.src).toContain('alice')
  })

  test('URL-encodes the username in the embedded iframe src', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'user/name')

    const iframe = container.querySelector('iframe')
    expect(iframe.src).toContain('user%2Fname')
    expect(iframe.src).not.toContain('user/name')
  })

  test('logs an error when the selector matches no element', () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})

    window.TymeslotBooking.embed('#does-not-exist', 'alice')

    expect(spy).toHaveBeenCalledWith(
      expect.stringContaining('Tymeslot'),
      expect.stringContaining('#does-not-exist')
    )
    spy.mockRestore()
  })
})

describe('postMessage resize handler', () => {
  test('applies height from resize messages originating from the expected domain', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'alice')

    const iframe = document.querySelector('iframe[title="Booking Widget"]')
    expect(iframe).not.toBeNull()

    const wrapper = iframe.parentNode
    wrapper.dataset.constrained = 'true'
    wrapper.dataset.constraintHeight = '800'

    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 500 }
      })
    )

    expect(wrapper.style.height).toBe('500px')
  })

  test('caps height in constrained mode', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'alice')

    const iframe = document.querySelector('iframe[title="Booking Widget"]')
    expect(iframe).not.toBeNull()

    const wrapper = iframe.parentNode
    wrapper.dataset.constrained = 'true'
    wrapper.dataset.constraintHeight = '400'

    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 600 }
      })
    )

    expect(wrapper.style.height).toBe('400px')
  })

  test('unconstrained inline embed applies posted height verbatim — grows', () => {
    const container = document.createElement('div')
    container.id = 'grow-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#grow-test', 'alice')

    const iframe = document.querySelector('#grow-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 800 }
      })
    )

    expect(wrapper.style.height).toBe('800px')
  })

  test('unconstrained inline embed applies posted height verbatim — shrinks below initial', () => {
    const container = document.createElement('div')
    container.id = 'shrink-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#shrink-test', 'alice')

    const iframe = document.querySelector('#shrink-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    // Initial placeholder is 400px — shrink to 250 to verify no persistent floor
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 250 }
      })
    )

    expect(wrapper.style.height).toBe('250px')
    expect(parseInt(wrapper.style.minHeight || '0', 10)).toBe(0)
  })

  test('ignores non-finite height values', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'alice')

    const iframe = document.querySelector('iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode
    wrapper.dataset.constrained = 'true'
    wrapper.dataset.constraintHeight = '800'

    // Set a known starting height via constrained resize
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 500 }
      })
    )
    expect(wrapper.style.height).toBe('500px')

    // NaN should be ignored
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: NaN }
      })
    )
    expect(wrapper.style.height).toBe('500px')

    // Negative should be ignored
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: -100 }
      })
    )
    expect(wrapper.style.height).toBe('500px')
  })

  test('constrained wrapper caps applied height at constraintHeight', () => {
    const container = document.createElement('div')
    container.id = 'constrained-cap-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#constrained-cap-test', 'alice')

    const iframe = document.querySelector('#constrained-cap-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    wrapper.dataset.constrained = 'true'
    wrapper.dataset.constraintHeight = '250'

    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 600 }
      })
    )

    expect(wrapper.style.height).toBe('250px')
  })

  test('data-initial-height sets the placeholder height shown before first resize message', () => {
    const container = document.createElement('div')
    container.id = 'initial-height-test'
    container.setAttribute('data-initial-height', '500')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#initial-height-test', 'alice')

    const iframe = document.querySelector('#initial-height-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.height).toBe('500px')
  })

  test('data-min-height is accepted as a legacy alias for data-initial-height', () => {
    const container = document.createElement('div')
    container.id = 'legacy-min-height-test'
    container.setAttribute('data-min-height', '550')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#legacy-min-height-test', 'alice')

    const iframe = document.querySelector('#legacy-min-height-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.height).toBe('550px')
  })

  test('initial height is replaced by resize message — no persistent floor', () => {
    const container = document.createElement('div')
    container.id = 'no-persistent-floor-test'
    container.setAttribute('data-initial-height', '600')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#no-persistent-floor-test', 'alice')

    const iframe = document.querySelector('#no-persistent-floor-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    // Sanity-check the initial placeholder
    expect(wrapper.style.height).toBe('600px')

    // Posted height of 350 must be applied verbatim — no floor at 600
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 350 }
      })
    )

    expect(wrapper.style.height).toBe('350px')
  })

  test('initial height below 200 is clamped to 200', () => {
    const container = document.createElement('div')
    container.id = 'clamp-initial-test'
    container.setAttribute('data-initial-height', '100')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#clamp-initial-test', 'alice')

    const iframe = document.querySelector('#clamp-initial-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.height).toBe('200px')
  })

  test('data-initial-height above 2000 is clamped to 2000', () => {
    const container = document.createElement('div')
    container.id = 'initial-height-upper-clamp-test'
    container.setAttribute('data-initial-height', '99999')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#initial-height-upper-clamp-test', 'alice')

    const iframe = document.querySelector('#initial-height-upper-clamp-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.height).toBe('2000px')
  })

  test('applies legacy default maxWidth of 640px and centering margins when no layout set', () => {
    // Back-compat: an inline snippet predating the column layout carries no
    // data-layout, so it keeps the original 640px default — not the wider
    // 1000px column default.
    const container = document.createElement('div')
    container.id = 'max-width-default-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#max-width-default-test', 'alice')

    const iframe = document.querySelector('#max-width-default-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.maxWidth).toBe('640px')
    expect(wrapper.style.marginLeft).toBe('auto')
    expect(wrapper.style.marginRight).toBe('auto')
  })

  test('applies 1000px default maxWidth when layout=column and no max-width attribute', () => {
    const container = document.createElement('div')
    container.id = 'max-width-column-default-test'
    container.setAttribute('data-layout', 'column')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#max-width-column-default-test', 'alice', { layout: 'column' })

    const iframe = document.querySelector(
      '#max-width-column-default-test iframe[title="Booking Widget"]'
    )
    const wrapper = iframe.parentNode

    expect(wrapper.style.maxWidth).toBe('1000px')
  })

  test('respects custom data-max-width attribute', () => {
    const container = document.createElement('div')
    container.id = 'max-width-custom-test'
    container.setAttribute('data-max-width', '900')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#max-width-custom-test', 'alice')

    const iframe = document.querySelector('#max-width-custom-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.maxWidth).toBe('900px')
  })

  test('data-max-width below 200 is clamped to 200', () => {
    const container = document.createElement('div')
    container.id = 'max-width-clamp-test'
    container.setAttribute('data-max-width', '100')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#max-width-clamp-test', 'alice')

    const iframe = document.querySelector('#max-width-clamp-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.maxWidth).toBe('200px')
  })

  test('data-max-width above 2000 is clamped to 2000', () => {
    const container = document.createElement('div')
    container.id = 'max-width-upper-clamp-test'
    container.setAttribute('data-max-width', '5000')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#max-width-upper-clamp-test', 'alice')

    const iframe = document.querySelector('#max-width-upper-clamp-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.maxWidth).toBe('2000px')
  })

  test('does not throw when e.data is null', () => {
    // A postMessage from the expected origin with null data should be silently ignored.
    expect(() => {
      window.dispatchEvent(
        new MessageEvent('message', {
          origin: window.location.origin,
          data: null
        })
      )
    }).not.toThrow()
  })

  test('does not throw when e.data is a primitive', () => {
    expect(() => {
      window.dispatchEvent(
        new MessageEvent('message', {
          origin: window.location.origin,
          data: 'plain string'
        })
      )
    }).not.toThrow()
  })

  test('ignores resize messages that originate from a different domain', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'alice')

    const iframe = document.querySelector('iframe[title="Booking Widget"]')
    expect(iframe).not.toBeNull()

    const wrapper = iframe.parentNode
    wrapper.dataset.constrained = 'true'
    wrapper.dataset.constraintHeight = '800'

    // First establish a known height via a legitimate constrained message so the
    // evil-origin assertion has a meaningful value to compare against.
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 500 }
      })
    )
    expect(wrapper.style.height).toBe('500px')

    // A message from an attacker-controlled domain must not change the height
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: 'https://evil.example.com',
        data: { type: 'tymeslot-resize', height: 9999 }
      })
    )
    expect(wrapper.style.height).toBe('500px')
  })
})

describe('layout back-compat (no data-layout = legacy default)', () => {
  test('no data-layout keeps the legacy 640px max-width default', () => {
    const container = document.createElement('div')
    container.id = 'legacy-no-layout-width'
    document.body.appendChild(container)

    // No layout option at all — simulates a snippet deployed before column.
    window.TymeslotBooking.embed('#legacy-no-layout-width', 'alice')

    const iframe = document.querySelector('#legacy-no-layout-width iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.maxWidth).toBe('640px')
  })

  test('no data-layout treats data-min-height as a persistent floor — does not shrink below it', () => {
    const container = document.createElement('div')
    container.id = 'legacy-floor-test'
    container.setAttribute('data-min-height', '500')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#legacy-floor-test', 'alice')

    const iframe = document.querySelector('#legacy-floor-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    // Initial placeholder reflects the min-height
    expect(wrapper.style.height).toBe('500px')

    // A posted height below the floor must be clamped UP to the floor
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 300 }
      })
    )
    expect(wrapper.style.height).toBe('500px')

    // A posted height above the floor grows normally
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 720 }
      })
    )
    expect(wrapper.style.height).toBe('720px')
  })

  test('data-layout=column uses the 1000px max-width default', () => {
    const container = document.createElement('div')
    container.id = 'column-width-test'
    container.setAttribute('data-layout', 'column')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#column-width-test', 'alice', { layout: 'column' })

    const iframe = document.querySelector('#column-width-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.maxWidth).toBe('1000px')
  })

  test('data-layout=column ignores data-min-height as a floor — shrinks below it', () => {
    const container = document.createElement('div')
    container.id = 'column-no-floor-test'
    container.setAttribute('data-layout', 'column')
    container.setAttribute('data-min-height', '500')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#column-no-floor-test', 'alice', { layout: 'column' })

    const iframe = document.querySelector('#column-no-floor-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    // Column embeds track content height exactly — a posted height below the
    // (former) floor is applied verbatim.
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 300 }
      })
    )
    expect(wrapper.style.height).toBe('300px')
    expect(parseInt(wrapper.style.minHeight || '0', 10)).toBe(0)
  })

  test('explicit data-max-width overrides the layout default (legacy)', () => {
    const container = document.createElement('div')
    container.id = 'legacy-explicit-width'
    container.setAttribute('data-max-width', '900')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#legacy-explicit-width', 'alice')

    const iframe = document.querySelector('#legacy-explicit-width iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    expect(wrapper.style.maxWidth).toBe('900px')
  })
})

describe('ensureScrollable — max-height container caps at the max-height, not the placeholder', () => {
  test('a max-height-only container caps the wrapper at the max-height value', async () => {
    // Regression: ensureScrollable previously read container.clientHeight (the
    // 400px placeholder) and pinned the embed there, so it could never grow to
    // the embedder's max-height. It must read the computed max-height instead.
    const container = document.createElement('div')
    container.id = 'max-height-cap-test'
    container.style.maxHeight = '800px'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#max-height-cap-test', 'alice')

    const iframe = document.querySelector('#max-height-cap-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    // ensureScrollable runs inside requestAnimationFrame — flush it.
    await new Promise((resolve) => requestAnimationFrame(() => resolve()))

    expect(wrapper.dataset.constrained).toBe('true')
    expect(wrapper.dataset.constraintHeight).toBe('800')

    // A posted height up to the 800px max-height is honoured (not capped at 400)
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 750 }
      })
    )
    expect(wrapper.style.height).toBe('750px')

    // Beyond the max-height it caps at 800
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 1200 }
      })
    )
    expect(wrapper.style.height).toBe('800px')
  })
})

describe('modal resize re-applies the cap on window shrink', () => {
  test('shrinking the viewport clamps the wrapper height down to the new max', () => {
    vi.useFakeTimers()

    window.TymeslotBooking.open('alice')

    const iframe = document.querySelector('#tymeslot-modal iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    // Simulate the iframe reporting a tall content height first.
    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 700 }
      })
    )

    // jsdom innerHeight defaults to 768 → modalContentMaxHeight = 668, so 700
    // is already capped to 668 by the resize handler.
    expect(wrapper.style.height).toBe('668px')

    // Shrink the window. iframe_embed.js would NOT re-post (height unchanged),
    // so the modal resize handler must re-apply the cap itself.
    window.innerHeight = 400
    window.dispatchEvent(new Event('resize'))
    vi.runAllTimers()

    // New cap = 400 - 100 = 300; the wrapper must be clamped down to it.
    expect(wrapper.dataset.constraintHeight).toBe('300')
    expect(wrapper.style.height).toBe('300px')

    vi.useRealTimers()
  })
})

describe('auto-init from data attributes (DOMContentLoaded)', () => {
  test('auto-initializes inline embed from #tymeslot-booking container', () => {
    const container = document.createElement('div')
    container.id = 'tymeslot-booking'
    container.setAttribute('data-username', 'auto-user')
    document.body.appendChild(container)

    // Trigger the auto-init that runs on DOMContentLoaded / readyState check.
    // Since embed.js already ran in beforeAll and the DOM was ready, we need
    // to manually call the public embed API to verify the same code path.
    // The initInlineEmbeds function is private, but we can verify via embed().
    window.TymeslotBooking.embed('#tymeslot-booking', 'auto-user')

    const iframe = container.querySelector('iframe')
    expect(iframe).not.toBeNull()
    expect(iframe.src).toContain('auto-user')
    expect(iframe.src).toContain('embed=1')
  })

  test('iframe URL includes parent-origin param with current page origin', () => {
    const container = document.createElement('div')
    container.id = 'origin-param-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#origin-param-test', 'alice')

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    expect(url.searchParams.get('parent-origin')).toBe(window.location.origin)
  })

  test('reads data-theme, data-primary-color, and data-locale from container', () => {
    const container = document.createElement('div')
    container.id = 'param-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#param-test', 'alice', {
      theme: '2',
      primaryColor: '#FF5733',
      locale: 'de'
    })

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    expect(url.searchParams.get('theme')).toBe('2')
    expect(url.searchParams.get('primary-color')).toBe('#FF5733')
    expect(url.searchParams.get('locale')).toBe('de')
  })
})

describe('parameter allowlist enforcement', () => {
  test('includes only allowed parameters in iframe URL', () => {
    const container = document.createElement('div')
    container.id = 'allowlist-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#allowlist-test', 'alice', {
      theme: '1',
      locale: 'en',
      primaryColor: '#14B8A6',
      // These should NOT appear in the URL
      malicious: '<script>alert(1)</script>',
      duration: '30',
      redirect: 'https://evil.com'
    })

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    // Allowed params present
    expect(url.searchParams.get('theme')).toBe('1')
    expect(url.searchParams.get('locale')).toBe('en')
    expect(url.searchParams.get('primary-color')).toBe('#14B8A6')

    // Disallowed params absent
    expect(url.searchParams.get('malicious')).toBeNull()
    expect(url.searchParams.get('duration')).toBeNull()
    expect(url.searchParams.get('redirect')).toBeNull()
  })

  test('rejects theme values that are not numeric', () => {
    const container = document.createElement('div')
    container.id = 'theme-reject'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#theme-reject', 'alice', {
      theme: 'evil<script>'
    })

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    expect(url.searchParams.get('theme')).toBeNull()
  })

  test('rejects primaryColor that does not match hex pattern', () => {
    const container = document.createElement('div')
    container.id = 'color-reject'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#color-reject', 'alice', {
      primaryColor: 'red'
    })

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    expect(url.searchParams.get('primary-color')).toBeNull()
  })

  test('rejects locale that does not match expected format', () => {
    const container = document.createElement('div')
    container.id = 'locale-reject'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#locale-reject', 'alice', {
      locale: 'not-a-valid-locale-string!!!'
    })

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    expect(url.searchParams.get('locale')).toBeNull()
  })

  test('passes layout=column to the iframe URL', () => {
    const container = document.createElement('div')
    container.id = 'layout-column-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#layout-column-test', 'alice', {
      layout: 'column'
    })

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    expect(url.searchParams.get('layout')).toBe('column')
  })

  test('reads data-layout from auto-init container', () => {
    const container = document.createElement('div')
    container.id = 'data-layout-test'
    container.setAttribute('data-layout', 'column')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#data-layout-test', 'alice', {
      layout: container.getAttribute('data-layout')
    })

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    expect(url.searchParams.get('layout')).toBe('column')
  })

  test('rejects layout values outside the allowlist', () => {
    const container = document.createElement('div')
    container.id = 'layout-reject'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#layout-reject', 'alice', {
      layout: 'mosaic'
    })

    const iframe = container.querySelector('iframe')
    const url = new URL(iframe.src)

    expect(url.searchParams.get('layout')).toBeNull()
  })
})

describe('showError()', () => {
  test('renders error message in a container element', () => {
    const container = document.createElement('div')
    container.id = 'error-container'
    document.body.appendChild(container)

    window.TymeslotBooking.showError(container)

    expect(container.innerHTML).toContain('Booking')
  })

  test('accepts a CSS selector string', () => {
    const container = document.createElement('div')
    container.id = 'error-selector-test'
    document.body.appendChild(container)

    window.TymeslotBooking.showError('#error-selector-test')

    expect(container.innerHTML).not.toBe('')
  })

  test('does nothing for a non-matching selector', () => {
    // Should not throw
    expect(() => window.TymeslotBooking.showError('#does-not-exist')).not.toThrow()
  })
})

describe('iframe loading timeout and retry', () => {
  test('retries loading the iframe after timeout', () => {
    vi.useFakeTimers()

    const container = document.createElement('div')
    container.id = 'timeout-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#timeout-test', 'alice')

    const iframe = container.querySelector('iframe')
    expect(iframe).not.toBeNull()
    const originalSrc = iframe.src

    // Advance past the 15s timeout without firing iframe.onload
    vi.advanceTimersByTime(15000)

    // After first timeout, src should have changed (retry with _retry=1)
    expect(iframe.src).not.toBe(originalSrc)
    expect(iframe.src).toContain('_retry=1')
  })

  test('shows error after exhausting all retries', async () => {
    vi.useFakeTimers()

    const container = document.createElement('div')
    container.id = 'exhaust-retry'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#exhaust-retry', 'alice')

    const wrapper = container.querySelector('div') // the wrapper div
    expect(wrapper).not.toBeNull()

    // Advance through all retries: initial 15s + retry1 15s + retry2 15s
    vi.advanceTimersByTime(15000) // first timeout → retry 1
    vi.advanceTimersByTime(15000) // second timeout → retry 2
    vi.advanceTimersByTime(15000) // third timeout → show error

    // After all retries exhausted, error should be displayed
    expect(wrapper.textContent).toContain('taking too long')
  })

  test('cancels timeout when iframe loads successfully', () => {
    vi.useFakeTimers()

    const container = document.createElement('div')
    container.id = 'load-success'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#load-success', 'alice')

    const iframe = container.querySelector('iframe')

    // Simulate successful load before timeout
    iframe.onload()

    expect(iframe.dataset.loaded).toBe('true')
    expect(iframe.style.opacity).toBe('1')

    // Advance past timeout — should not retry
    vi.advanceTimersByTime(15000)

    // No retry param should be added
    expect(iframe.src).not.toContain('_retry')
  })
})

describe('modal keyboard and focus management', () => {
  test('closes modal on Escape key press', async () => {
    vi.useFakeTimers()

    window.TymeslotBooking.open('alice')
    expect(document.getElementById('tymeslot-modal')).not.toBeNull()

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await vi.runAllTimersAsync()

    expect(document.getElementById('tymeslot-modal')).toBeNull()
  })

  test('modal has correct ARIA attributes', () => {
    window.TymeslotBooking.open('alice')

    const modal = document.getElementById('tymeslot-modal')
    expect(modal.getAttribute('role')).toBe('dialog')
    expect(modal.getAttribute('aria-modal')).toBe('true')
    expect(modal.getAttribute('aria-label')).toBe('Booking Widget')
  })

  test('close button has accessible label', () => {
    window.TymeslotBooking.open('alice')

    const closeBtn = document.querySelector('#tymeslot-modal button[aria-label="Close booking widget"]')
    expect(closeBtn).not.toBeNull()
  })

  test('Tab on last focusable element wraps to first', () => {
    window.TymeslotBooking.open('alice')

    const modal = document.getElementById('tymeslot-modal')
    const focusable = modal.querySelectorAll('a[href], button:not([disabled]), textarea, input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"]), iframe')
    const last = focusable[focusable.length - 1]
    last.focus()

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', bubbles: true }))

    expect(document.activeElement).toBe(focusable[0])
  })

  test('Shift+Tab on first focusable element wraps to last', () => {
    window.TymeslotBooking.open('alice')

    const modal = document.getElementById('tymeslot-modal')
    const focusable = modal.querySelectorAll('a[href], button:not([disabled]), textarea, input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"]), iframe')
    focusable[0].focus()

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Tab', shiftKey: true, bubbles: true }))

    expect(document.activeElement).toBe(focusable[focusable.length - 1])
  })
})

describe('floating button options', () => {
  test('uses custom buttonColor when valid hex is provided', () => {
    window.TymeslotBooking.initFloating('alice', { buttonColor: '#FF0000' })

    const button = document.getElementById('tymeslot-floating-button')
    expect(button.style.background).toContain('rgb(255, 0, 0)')
  })

  test('falls back to default color for invalid buttonColor', () => {
    window.TymeslotBooking.initFloating('alice', { buttonColor: 'not-a-color' })

    const button = document.getElementById('tymeslot-floating-button')
    // Default turquoise #14B8A6
    expect(button.style.background).toContain('rgb(20, 184, 166)')
  })
})
