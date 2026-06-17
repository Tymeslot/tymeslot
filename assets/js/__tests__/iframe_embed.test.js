/**
 * Tests for iframe_embed.js — the script that runs inside embedded iframes.
 *
 * Covers the continuous resize protocol:
 * - Embedded context detection (window.self !== window.top)
 * - data-embedded attribute on <html>
 * - Consistent height = computed main + margins every pass (no first-pass lurch)
 * - Grow immediately, settle a shrink for one tick, skip sub-pixel jitter
 * - Origin derivation from document.referrer / parent-origin param
 * - Graceful degradation when referrer is unavailable
 */

import { beforeEach, afterEach, describe, expect, test, vi } from 'vitest'
import { readFileSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const iframeEmbedSource = readFileSync(
  resolve(__dirname, '../iframe_embed.js'),
  'utf-8'
)

/**
 * Execute iframe_embed.js in a controlled environment.
 *
 * The IIFE checks `window.self !== window.top` immediately, so we need
 * to set that up before evaluating the script. We also control
 * `document.referrer` and capture `postMessage` calls. setTimeout is
 * stubbed so each tick of the resize loop is observable.
 */
function runScript({
  isEmbedded = true,
  referrer = 'https://embedder.com/page',
  search = '',
  scrollHeight = 800,
  mainHeight = 600,
  mainMarginTop = 0,
  mainMarginBottom = 0
} = {}) {
  if (isEmbedded) {
    Object.defineProperty(window, 'top', {
      value: { not: 'self' },
      writable: true,
      configurable: true
    })
  } else {
    Object.defineProperty(window, 'top', {
      value: window.self,
      writable: true,
      configurable: true
    })
  }

  Object.defineProperty(document, 'referrer', {
    value: referrer,
    writable: true,
    configurable: true
  })

  if (search) {
    delete window.location
    window.location = new URL('http://localhost' + search)
  }

  // Mock the height measurements
  Object.defineProperty(document.documentElement, 'scrollHeight', {
    value: scrollHeight,
    configurable: true,
    writable: true
  })

  // Mock getComputedStyle for the main element measurement
  const origGetComputedStyle = window.getComputedStyle
  window.getComputedStyle = vi.fn((el) => {
    if (el === document.documentElement || el.tagName === 'MAIN' || el.classList?.contains('main')) {
      return {
        height: `${mainHeight}px`,
        marginTop: `${mainMarginTop}px`,
        marginBottom: `${mainMarginBottom}px`
      }
    }
    return origGetComputedStyle(el)
  })

  window.parent.postMessage = vi.fn()

  // Capture the setTimeout callback so tests can advance ticks manually.
  // Each call schedules the next iteration; we let tests drive the loop.
  const scheduled = []
  window.setTimeout = vi.fn((cb, _ms) => {
    scheduled.push(cb)
    return scheduled.length
  })

  // eslint-disable-next-line no-eval
  eval(iframeEmbedSource)

  return {
    advance: () => {
      const cb = scheduled.shift()
      if (cb) cb()
    },
    scheduledCount: () => scheduled.length
  }
}

const originalLocation = window.location

beforeEach(() => {
  document.documentElement.removeAttribute('data-embedded')
  document.documentElement.removeAttribute('data-embed-mode')
  document.body.innerHTML = ''
  vi.restoreAllMocks()

  if (window.location !== originalLocation) {
    delete window.location
    window.location = originalLocation
  }
})

afterEach(() => {
  Object.defineProperty(window, 'top', {
    value: window.self,
    writable: true,
    configurable: true
  })
})

describe('embedded context detection', () => {
  test('sets data-embedded attribute on <html> when inside an iframe', () => {
    runScript({ isEmbedded: true })

    expect(document.documentElement.hasAttribute('data-embedded')).toBe(true)
  })

  test('does not set the dead data-embed-mode attribute', () => {
    // The embed-mode protocol was removed: both inline and modal embeds report
    // height continuously and no CSS consumes data-embed-mode.
    runScript({ isEmbedded: true, search: '?embed-mode=inline' })

    expect(document.documentElement.hasAttribute('data-embed-mode')).toBe(false)
  })

  test('does not set data-embedded when not inside an iframe', () => {
    runScript({ isEmbedded: false })

    expect(document.documentElement.hasAttribute('data-embedded')).toBe(false)
  })

  test('does not post any messages when not embedded', () => {
    runScript({ isEmbedded: false })

    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })
})

describe('continuous resize protocol', () => {
  test('first measurement uses computed main height + margins with isFirstTime: true', () => {
    runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 1000,
      mainHeight: 500
    })

    // Consistent measurement from the first pass — no generous-scrollHeight lurch.
    expect(window.parent.postMessage).toHaveBeenCalledWith(
      { type: 'tymeslot-resize', height: 500, isFirstTime: true },
      'https://embedder.com'
    )
  })

  test('includes the main element margins in the measured height', () => {
    runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 1000,
      mainHeight: 600,
      mainMarginTop: 10,
      mainMarginBottom: 20
    })

    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)
    expect(window.parent.postMessage).toHaveBeenCalledWith(
      { type: 'tymeslot-resize', height: 630, isFirstTime: true },
      'https://embedder.com'
    )
  })

  test('skips reposting when measured height is unchanged', () => {
    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 800,
      mainHeight: 800
    })

    // First post: computed height 800 (isFirstTime: true)
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)

    handle.advance()
    // Next pass measures 800 again — same value, no post
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)

    handle.advance()
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)
  })

  test('grows immediately to a larger height', () => {
    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 1000,
      mainHeight: 500
    })

    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)

    // Content expands — growth is posted on the very next tick, no settle wait.
    window.getComputedStyle = vi.fn(() => ({
      height: '900px',
      marginTop: '0px',
      marginBottom: '0px'
    }))

    handle.advance()

    expect(window.parent.postMessage).toHaveBeenCalledTimes(2)
    expect(window.parent.postMessage).toHaveBeenLastCalledWith(
      { type: 'tymeslot-resize', height: 900, isFirstTime: false },
      'https://embedder.com'
    )
  })

  test('settles a shrink for one tick before reposting (no flicker)', () => {
    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 1000,
      mainHeight: 1000
    })

    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)

    // Simulate the booking page collapsing to a shorter step
    window.getComputedStyle = vi.fn(() => ({
      height: '400px',
      marginTop: '0px',
      marginBottom: '0px'
    }))

    // A shrink is debounced: the first tick records the new height; the next
    // tick (now steady) posts it. This collapses a reflow's intermediate frames.
    handle.advance()
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)

    handle.advance()
    expect(window.parent.postMessage).toHaveBeenCalledTimes(2)
    expect(window.parent.postMessage).toHaveBeenLastCalledWith(
      { type: 'tymeslot-resize', height: 400, isFirstTime: false },
      'https://embedder.com'
    )
  })

  test('schedules the next tick after each post', () => {
    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/'
    })

    // The initial run scheduled one tick
    expect(handle.scheduledCount()).toBeGreaterThanOrEqual(1)

    handle.advance()
    // After the tick, another one should be scheduled
    expect(handle.scheduledCount()).toBeGreaterThanOrEqual(1)
  })

  test('does not post height less than 1', () => {
    runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 0,
      mainHeight: 0
    })

    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })

  test('skips measurement when document is hidden and resumes on visibilitychange', () => {
    // Mark the document as hidden before running the script
    Object.defineProperty(document, 'hidden', {
      value: true,
      writable: true,
      configurable: true
    })

    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 800,
      mainHeight: 600
    })

    // The initial loop() call should have been skipped — no postMessage
    expect(window.parent.postMessage).not.toHaveBeenCalled()

    // Advance several poll ticks — still hidden, still no postMessage
    handle.advance()
    handle.advance()
    expect(window.parent.postMessage).not.toHaveBeenCalled()

    // Page becomes visible — visibilitychange should trigger an immediate postHeight()
    Object.defineProperty(document, 'hidden', {
      value: false,
      writable: true,
      configurable: true
    })
    document.dispatchEvent(new Event('visibilitychange'))

    expect(window.parent.postMessage).toHaveBeenCalledWith(
      { type: 'tymeslot-resize', height: 600, isFirstTime: true },
      'https://embedder.com'
    )
  })

  test('never uses "*" as target origin', () => {
    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/'
    })
    handle.advance()

    for (const call of window.parent.postMessage.mock.calls) {
      expect(call[1]).not.toBe('*')
    }
  })

  test('sub-pixel jitter is suppressed by Math.ceil — two heights differing by <1px produce one post', () => {
    // First measurement: mainHeight 600.2 → Math.ceil(600.2) = 601
    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 602,
      mainHeight: 600.2
    })

    // Initial script run posts height 601
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)
    expect(window.parent.postMessage).toHaveBeenCalledWith(
      { type: 'tymeslot-resize', height: 601, isFirstTime: true },
      'https://embedder.com'
    )

    // Second measurement: 600.7px → Math.ceil(600.7) = 601 (same ceiled value)
    window.getComputedStyle = vi.fn(() => ({
      height: '600.7px',
      marginTop: '0px',
      marginBottom: '0px'
    }))

    handle.advance()

    // No second post — identical ceiled value is suppressed, not a sub-pixel guard
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)
  })

  test('postMessage failure does not crash the resize loop', () => {
    window.parent.postMessage = vi.fn(() => {
      throw new Error('cross-origin postMessage blocked')
    })

    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 800,
      mainHeight: 600
    })

    // First post threw — loop must still have scheduled a next tick
    expect(handle.scheduledCount()).toBeGreaterThanOrEqual(1)

    // Advance a tick; content changes so there will be another post attempt
    window.getComputedStyle = vi.fn(() => ({
      height: '700px',
      marginTop: '0px',
      marginBottom: '0px'
    }))

    // This must not throw
    expect(() => handle.advance()).not.toThrow()

    // Loop continues scheduling despite repeated failures
    expect(handle.scheduledCount()).toBeGreaterThanOrEqual(1)
  })

  test('falls back to documentElement.scrollHeight when getComputedStyle height is non-numeric', () => {
    // First tick: normal computed height so the loop starts cleanly.
    const handle = runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/',
      scrollHeight: 600,
      mainHeight: 500
    })

    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)

    // Simulate a layout state where computed height resolves to 'auto' (unresolved).
    // measureHeight() must fall back to documentElement.scrollHeight in this case.
    window.getComputedStyle = vi.fn(() => ({
      height: 'auto',
      marginTop: '0px',
      marginBottom: '0px'
    }))
    Object.defineProperty(document.documentElement, 'scrollHeight', {
      value: 850,
      configurable: true,
      writable: true
    })

    handle.advance()

    // The fallback posts scrollHeight (850), not NaN from the unresolvable height.
    expect(window.parent.postMessage).toHaveBeenCalledTimes(2)
    expect(window.parent.postMessage).toHaveBeenLastCalledWith(
      { type: 'tymeslot-resize', height: 850, isFirstTime: false },
      'https://embedder.com'
    )
  })
})

describe('parent origin derivation', () => {
  test('derives target origin from document.referrer', () => {
    runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/some/page',
      scrollHeight: 500
    })

    expect(window.parent.postMessage).toHaveBeenCalledWith(
      expect.any(Object),
      'https://embedder.com'
    )
  })

  test('uses parent-origin URL param when referrer is empty', () => {
    runScript({
      isEmbedded: true,
      referrer: '',
      search: '?embed=1&parent-origin=https://mysite.com',
      scrollHeight: 500
    })

    expect(window.parent.postMessage).toHaveBeenCalledWith(
      expect.any(Object),
      'https://mysite.com'
    )
  })

  test('prefers referrer over parent-origin param when both are available', () => {
    runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/page',
      search: '?embed=1&parent-origin=https://other.com',
      scrollHeight: 500
    })

    expect(window.parent.postMessage).toHaveBeenCalledWith(
      expect.any(Object),
      'https://embedder.com'
    )
  })

  test('warns and disables resize when no parent origin can be determined', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    runScript({ isEmbedded: true, referrer: '', search: '' })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })

  test('rejects parent-origin with non-http(s) scheme', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    runScript({
      isEmbedded: true,
      referrer: '',
      search: '?parent-origin=javascript://evil.com'
    })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })

  test('handles malformed referrer URL gracefully', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    runScript({ isEmbedded: true, referrer: ':::not-a-url' })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })
})
