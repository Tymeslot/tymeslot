/**
 * Behavioural tests for the BookingSuccess Phoenix LiveView hook.
 *
 * On `booking_success` the hook posts the booking to the embedding page, but
 * only to the parent origin the server vouches for (`data-parent-origin`).
 * embed.js acks; a frame placed without embed.js never does, so after
 * ACK_TIMEOUT_MS the hook redirects the top window itself, falling back to a
 * new tab when the browser refuses.
 */

import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { ACK_TIMEOUT_MS, BookingSuccess } from '../hooks/booking_success'

const PARENT_ORIGIN = 'https://embedder.example'

function createHookInstance({ parentOrigin = PARENT_ORIGIN } = {}) {
  const events = {}
  const el = document.createElement('div')
  if (parentOrigin !== null) el.dataset.parentOrigin = parentOrigin

  return {
    el,
    handleEvent(name, cb) {
      events[name] = cb
    },
    _trigger(name, payload) {
      events[name]?.(payload)
    },
  }
}

function mount(opts) {
  const hook = createHookInstance(opts)
  BookingSuccess.mounted.call(hook)
  return hook
}

// jsdom's window is its own parent, so the parent's postMessage is window's.
function ack({ source = window, origin = PARENT_ORIGIN } = {}) {
  window.dispatchEvent(
    new MessageEvent('message', {
      source,
      origin,
      data: { type: 'tymeslot-booking-success-ack' },
    })
  )
}

describe('BookingSuccess', () => {
  let postSpy
  let openSpy
  let topLocation
  let hooks

  beforeEach(() => {
    vi.useFakeTimers()
    hooks = []
    postSpy = vi.spyOn(window, 'postMessage').mockImplementation(() => {})
    openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
    topLocation = { href: 'https://embedder.example/book' }
    vi.spyOn(window, 'top', 'get').mockReturnValue({ location: topLocation })
  })

  afterEach(() => {
    hooks.forEach(hook => BookingSuccess.destroyed.call(hook))
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  function mountTracked(opts) {
    const hook = mount(opts)
    hooks.push(hook)
    return hook
  }

  const data = { eventTypeName: 'Intro', inviteeEmail: 'ada@example.com' }
  const redirect_url = 'https://embedder.example/thanks?event=Intro'

  test('posts the booking to the verified parent origin, never "*"', () => {
    const hook = mountTracked()
    hook._trigger('booking_success', { redirect_url, data })

    expect(postSpy).toHaveBeenCalledTimes(1)
    expect(postSpy).toHaveBeenCalledWith(
      { type: 'tymeslot-booking-success', data, redirectUrl: redirect_url },
      PARENT_ORIGIN
    )
  })

  test('an ack from the parent within the timeout leaves the redirect to embed.js', () => {
    const hook = mountTracked()
    hook._trigger('booking_success', { redirect_url, data })
    ack()
    vi.advanceTimersByTime(ACK_TIMEOUT_MS + 100)

    expect(topLocation.href).toBe('https://embedder.example/book')
    expect(openSpy).not.toHaveBeenCalled()
  })

  test('without an ack, redirects the top window after the timeout', () => {
    const hook = mountTracked()
    hook._trigger('booking_success', { redirect_url, data })

    vi.advanceTimersByTime(ACK_TIMEOUT_MS - 1)
    expect(topLocation.href).toBe('https://embedder.example/book')

    vi.advanceTimersByTime(1)
    expect(topLocation.href).toBe(redirect_url)
    expect(openSpy).not.toHaveBeenCalled()
  })

  test('waits about 1.5 s for the ack, so a busy parent is not raced', () => {
    expect(ACK_TIMEOUT_MS).toBeGreaterThanOrEqual(1500)

    const hook = mountTracked()
    hook._trigger('booking_success', { redirect_url, data })
    vi.advanceTimersByTime(1000)
    expect(topLocation.href).toBe('https://embedder.example/book')

    // A late ack, still inside the window, cancels the fallback.
    ack()
    vi.advanceTimersByTime(ACK_TIMEOUT_MS)
    expect(topLocation.href).toBe('https://embedder.example/book')
  })

  test('opens a new tab when the browser blocks top navigation', () => {
    window.top.location = {
      set href(_value) {
        throw new Error('SecurityError')
      },
    }
    const hook = mountTracked()
    hook._trigger('booking_success', { redirect_url, data })
    vi.advanceTimersByTime(ACK_TIMEOUT_MS)

    expect(openSpy).toHaveBeenCalledWith(redirect_url, '_blank', 'noopener')
  })

  test('ignores an ack that does not come from the parent window', () => {
    const foreign = document.createElement('iframe')
    document.body.appendChild(foreign)
    const hook = mountTracked()
    hook._trigger('booking_success', { redirect_url, data })
    ack({ source: foreign.contentWindow })
    ack({ origin: 'https://evil.example' })
    vi.advanceTimersByTime(ACK_TIMEOUT_MS)

    expect(topLocation.href).toBe(redirect_url)
    foreign.remove()
  })

  test('posts nothing without a verified parent origin', () => {
    const hook = mountTracked({ parentOrigin: null })
    hook._trigger('booking_success', { redirect_url, data })

    expect(postSpy).not.toHaveBeenCalled()
  })

  test('posts nothing when the parent origin is not an http(s) origin', () => {
    const hook = mountTracked({ parentOrigin: 'javascript:alert(1)' })
    hook._trigger('booking_success', { redirect_url, data })

    expect(postSpy).not.toHaveBeenCalled()
  })

  test('without a verified origin, still redirects the top window after the timeout', () => {
    const hook = mountTracked({ parentOrigin: null })
    hook._trigger('booking_success', { redirect_url, data })
    vi.advanceTimersByTime(ACK_TIMEOUT_MS)

    expect(topLocation.href).toBe(redirect_url)
  })

  test('does not navigate when there is no redirect URL', () => {
    const hook = mountTracked()
    hook._trigger('booking_success', { redirect_url: null, data })
    vi.advanceTimersByTime(ACK_TIMEOUT_MS)

    expect(postSpy).toHaveBeenCalledWith(
      { type: 'tymeslot-booking-success', data, redirectUrl: null },
      PARENT_ORIGIN
    )
    expect(topLocation.href).toBe('https://embedder.example/book')
    expect(openSpy).not.toHaveBeenCalled()
  })

  test('drops a redirect URL without an http(s) scheme', () => {
    const hook = mountTracked()
    hook._trigger('booking_success', { redirect_url: 'javascript:alert(1)', data })
    vi.advanceTimersByTime(ACK_TIMEOUT_MS)

    expect(postSpy).toHaveBeenCalledWith(
      { type: 'tymeslot-booking-success', data, redirectUrl: null },
      PARENT_ORIGIN
    )
    expect(topLocation.href).toBe('https://embedder.example/book')
  })

  test('destroyed() cancels a pending fallback', () => {
    const hook = mount()
    hook._trigger('booking_success', { redirect_url, data })
    BookingSuccess.destroyed.call(hook)
    vi.advanceTimersByTime(ACK_TIMEOUT_MS)

    expect(topLocation.href).toBe('https://embedder.example/book')
  })
})
