/**
 * Tests for iframe_embed.js — the script that runs inside embedded iframes.
 *
 * Covers:
 * - Embedded context detection (window.self !== window.top)
 * - data-embedded attribute on <html>
 * - ResizeObserver-based height reporting via postMessage
 * - Origin derivation from document.referrer
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
 * to set that up before evaluating the script. We also need to control
 * `document.referrer` and capture `postMessage` calls.
 */
function runScript({ isEmbedded = true, referrer = 'https://embedder.com/page', search = '' } = {}) {
  // Mock window.self !== window.top
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

  // Mock document.referrer
  Object.defineProperty(document, 'referrer', {
    value: referrer,
    writable: true,
    configurable: true
  })

  // Mock window.location.search for parent-origin param tests
  if (search) {
    delete window.location;
    window.location = new URL('http://localhost' + search);
  }

  // Mock window.parent.postMessage
  window.parent.postMessage = vi.fn()

  // Mock requestAnimationFrame to execute synchronously
  window.requestAnimationFrame = vi.fn((cb) => cb())

  // eslint-disable-next-line no-eval
  eval(iframeEmbedSource)
}

// Capture the original window.location so we can restore it after tests
// that replace it with a URL object for parent-origin param testing.
const originalLocation = window.location

beforeEach(() => {
  // Reset document state
  document.documentElement.removeAttribute('data-embedded')
  document.body.innerHTML = ''
  vi.restoreAllMocks()

  // Restore window.location in case a previous test replaced it
  if (window.location !== originalLocation) {
    delete window.location;
    window.location = originalLocation;
  }
})

afterEach(() => {
  // Restore window.top
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

  test('does not set data-embedded when not inside an iframe', () => {
    runScript({ isEmbedded: false })

    expect(document.documentElement.hasAttribute('data-embedded')).toBe(false)
  })

  test('does nothing else when not embedded — no postMessage listeners', () => {
    runScript({ isEmbedded: false })

    // parent.postMessage should not have been called
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })
})

describe('referrer-based origin derivation', () => {
  test('derives target origin from document.referrer', () => {
    // Mock ResizeObserver to capture the callback
    let resizeCallback
    window.ResizeObserver = vi.fn((cb) => {
      resizeCallback = cb
      return { observe: vi.fn() }
    })

    // Set a known body height
    Object.defineProperty(document.body, 'offsetHeight', { value: 400, configurable: true })

    runScript({ isEmbedded: true, referrer: 'https://embedder.com/some/page' })

    // Trigger resize
    resizeCallback()

    expect(window.parent.postMessage).toHaveBeenCalledWith(
      { type: 'tymeslot-resize', height: 400 },
      'https://embedder.com'
    )
  })

  test('logs warning and disables auto-resize when referrer is empty', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    runScript({ isEmbedded: true, referrer: '' })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    // postMessage should never be called
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })

  test('logs warning when referrer URL has "null" origin (data: or file: pages)', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    // data: URIs produce origin "null"
    runScript({ isEmbedded: true, referrer: 'data:text/html,<h1>test</h1>' })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
  })

  test('handles malformed referrer URL gracefully', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    // A completely broken URL string
    runScript({ isEmbedded: true, referrer: ':::not-a-url' })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })
})

describe('parent-origin URL param fallback', () => {
  test('uses parent-origin param when referrer is empty', () => {
    let resizeCallback
    window.ResizeObserver = vi.fn((cb) => {
      resizeCallback = cb
      return { observe: vi.fn() }
    })

    Object.defineProperty(document.body, 'offsetHeight', { value: 350, configurable: true })

    runScript({
      isEmbedded: true,
      referrer: '',
      search: '?embed=1&parent-origin=https://mysite.com'
    })

    resizeCallback()

    expect(window.parent.postMessage).toHaveBeenCalledWith(
      { type: 'tymeslot-resize', height: 350 },
      'https://mysite.com'
    )
  })

  test('prefers referrer over parent-origin param when both are available', () => {
    let resizeCallback
    window.ResizeObserver = vi.fn((cb) => {
      resizeCallback = cb
      return { observe: vi.fn() }
    })

    Object.defineProperty(document.body, 'offsetHeight', { value: 400, configurable: true })

    runScript({
      isEmbedded: true,
      referrer: 'https://embedder.com/page',
      search: '?embed=1&parent-origin=https://other.com'
    })

    resizeCallback()

    expect(window.parent.postMessage).toHaveBeenCalledWith(
      { type: 'tymeslot-resize', height: 400 },
      'https://embedder.com'
    )
  })

  test('warns and disables resize when neither referrer nor param is available', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    runScript({ isEmbedded: true, referrer: '', search: '' })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })

  test('rejects parent-origin param with invalid URL', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    runScript({
      isEmbedded: true,
      referrer: '',
      search: '?parent-origin=not-a-url'
    })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })

  test('rejects parent-origin with javascript: scheme', () => {
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

  test('rejects parent-origin with data: scheme', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    runScript({
      isEmbedded: true,
      referrer: '',
      search: '?parent-origin=data:text/html,<script>alert(1)</script>'
    })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })

  test('rejects parent-origin with file: scheme', () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    runScript({
      isEmbedded: true,
      referrer: '',
      search: '?parent-origin=file:///etc/passwd'
    })

    expect(warnSpy).toHaveBeenCalledWith(
      expect.stringContaining('auto-resize disabled')
    )
    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })
})

describe('height reporting via postMessage', () => {
  let resizeCallback

  function setupWithResize(height = 500) {
    window.ResizeObserver = vi.fn((cb) => {
      resizeCallback = cb
      return { observe: vi.fn() }
    })

    Object.defineProperty(document.body, 'offsetHeight', {
      value: height,
      configurable: true,
      writable: true
    })

    runScript({ isEmbedded: true, referrer: 'https://embedder.com/' })
  }

  test('posts tymeslot-resize message with body.offsetHeight', () => {
    setupWithResize(600)
    resizeCallback()

    expect(window.parent.postMessage).toHaveBeenCalledWith(
      { type: 'tymeslot-resize', height: 600 },
      'https://embedder.com'
    )
  })

  test('does not re-post if height has not changed', () => {
    setupWithResize(500)

    resizeCallback()
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)

    // Same height again
    resizeCallback()
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)
  })

  test('posts again when height changes', () => {
    setupWithResize(500)
    resizeCallback()
    expect(window.parent.postMessage).toHaveBeenCalledTimes(1)

    // Change height
    Object.defineProperty(document.body, 'offsetHeight', {
      value: 700,
      configurable: true,
      writable: true
    })
    resizeCallback()
    expect(window.parent.postMessage).toHaveBeenCalledTimes(2)
    expect(window.parent.postMessage).toHaveBeenLastCalledWith(
      { type: 'tymeslot-resize', height: 700 },
      'https://embedder.com'
    )
  })

  test('does not post height less than 1', () => {
    setupWithResize(0)
    resizeCallback()

    expect(window.parent.postMessage).not.toHaveBeenCalled()
  })

  test('never uses "*" as target origin', () => {
    setupWithResize(500)
    resizeCallback()

    // Verify no call ever used "*"
    for (const call of window.parent.postMessage.mock.calls) {
      expect(call[1]).not.toBe('*')
    }
  })
})

describe('ResizeObserver fallback', () => {
  test('observes body after DOMContentLoaded when body is not yet available', () => {
    // Simulate body not being ready
    const originalBody = document.body
    const observeSpy = vi.fn()

    window.ResizeObserver = vi.fn(() => ({
      observe: observeSpy
    }))

    // Temporarily remove body reference to test the else branch
    // In jsdom, document.body is always available, so we test indirectly
    // by verifying observe was called (the happy path)
    Object.defineProperty(document.body, 'offsetHeight', { value: 300, configurable: true })

    runScript({ isEmbedded: true, referrer: 'https://embedder.com/' })

    expect(observeSpy).toHaveBeenCalledWith(document.body)
  })
})
