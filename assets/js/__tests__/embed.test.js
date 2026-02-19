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
  test('ignores resize messages that originate from a different domain', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'alice')

    const iframe = document.querySelector('iframe[title="Booking Widget"]')
    const initialHeight = iframe?.style.height ?? ''

    window.dispatchEvent(
      new MessageEvent('message', {
        origin: 'https://evil.example.com',
        data: { type: 'tymeslot-resize', height: 9999 }
      })
    )

    // Height must not have changed — the message was from the wrong origin
    expect(iframe?.style.height ?? '').toBe(initialHeight)
  })
})
