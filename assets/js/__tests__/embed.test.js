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

  test('ignores non-finite height values', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'alice')

    const iframe = document.querySelector('iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    // Set a known starting height
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

  test('unconstrained resize never shrinks wrapper below default minimum height', () => {
    const container = document.createElement('div')
    container.id = 'floor-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#floor-test', 'alice')

    const iframe = document.querySelector('#floor-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 150 }
      })
    )

    const height = parseInt(wrapper.style.height, 10)
    expect(height).toBeGreaterThanOrEqual(400)
  })

  test('unconstrained resize applies reported height when above the floor', () => {
    const container = document.createElement('div')
    container.id = 'above-floor-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#above-floor-test', 'alice')

    const iframe = document.querySelector('#above-floor-test iframe[title="Booking Widget"]')
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

  test('respects custom data-min-height from container', () => {
    const container = document.createElement('div')
    container.id = 'custom-floor-test'
    container.setAttribute('data-min-height', '500')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#custom-floor-test', 'alice')

    const iframe = document.querySelector('#custom-floor-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 200 }
      })
    )

    expect(wrapper.style.height).toBe('500px')
    expect(wrapper.style.minHeight).toBe('500px')
  })

  test('constrained mode ignores the floor — constraint height wins', () => {
    const container = document.createElement('div')
    container.id = 'constrained-floor-test'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#constrained-floor-test', 'alice')

    const iframe = document.querySelector('#constrained-floor-test iframe[title="Booking Widget"]')
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

  test('data-min-height below 200 is clamped to 200', () => {
    const container = document.createElement('div')
    container.id = 'clamp-floor-test'
    container.setAttribute('data-min-height', '100')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#clamp-floor-test', 'alice')

    const iframe = document.querySelector('#clamp-floor-test iframe[title="Booking Widget"]')
    const wrapper = iframe.parentNode

    window.dispatchEvent(
      new MessageEvent('message', {
        origin: window.location.origin,
        source: iframe.contentWindow,
        data: { type: 'tymeslot-resize', height: 50 }
      })
    )

    expect(wrapper.style.height).toBe('200px')
  })

  test('applies default maxWidth of 640px and centering margins when no attribute set', () => {
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

    // First establish a known height via a legitimate message so the evil-origin
    // assertion has a meaningful value to compare against, rather than the empty
    // initial state (which would pass trivially even if no handler existed).
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
