/**
 * Behavioural tests for the PaymentRedirectOpenTab Phoenix LiveView hook.
 *
 * The hook listens for the `payment_redirect_open_tab` server-pushed
 * event and calls `window.open(url, '_blank')`. This is the embed-iframe
 * escape hatch for paid bookings — Stripe Checkout cannot render inside
 * an iframe, so we bounce out to a new tab and rely on PubSub to flip
 * the iframe to confirmation when the webhook lands.
 */

import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'
import { PaymentRedirectOpenTab } from '../hooks/payment_redirect_open_tab'

function createHookInstance({ handlers } = {}) {
  const events = handlers || {}

  return {
    el: document.createElement('div'),
    handleEvent(name, cb) {
      events[name] = cb
    },
    _trigger(name, payload) {
      events[name]?.(payload)
    },
  }
}

describe('PaymentRedirectOpenTab', () => {
  let openSpy

  beforeEach(() => {
    openSpy = vi.spyOn(window, 'open').mockImplementation(() => null)
  })

  afterEach(() => {
    openSpy.mockRestore()
  })

  test('opens the URL in a new tab when the server event fires', () => {
    const hook = createHookInstance()
    PaymentRedirectOpenTab.mounted.call(hook)

    hook._trigger('payment_redirect_open_tab', {
      url: 'https://checkout.stripe.com/cs_TEST',
    })

    expect(openSpy).toHaveBeenCalledTimes(1)
    expect(openSpy).toHaveBeenCalledWith(
      'https://checkout.stripe.com/cs_TEST',
      '_blank',
      'noopener,noreferrer'
    )
  })

  test('ignores empty or non-string URLs (defensive)', () => {
    const hook = createHookInstance()
    PaymentRedirectOpenTab.mounted.call(hook)

    hook._trigger('payment_redirect_open_tab', { url: '' })
    hook._trigger('payment_redirect_open_tab', { url: null })
    hook._trigger('payment_redirect_open_tab', { url: 42 })
    hook._trigger('payment_redirect_open_tab', {})

    expect(openSpy).not.toHaveBeenCalled()
  })

  test('does not re-open the same URL twice on LiveView re-render bursts', () => {
    const hook = createHookInstance()
    PaymentRedirectOpenTab.mounted.call(hook)

    const url = 'https://checkout.stripe.com/cs_DEDUP'
    hook._trigger('payment_redirect_open_tab', { url })
    hook._trigger('payment_redirect_open_tab', { url })
    hook._trigger('payment_redirect_open_tab', { url })

    expect(openSpy).toHaveBeenCalledTimes(1)
  })

  test('opens a different URL even after a previous one (e.g. retry after expiry)', () => {
    const hook = createHookInstance()
    PaymentRedirectOpenTab.mounted.call(hook)

    hook._trigger('payment_redirect_open_tab', { url: 'https://stripe/old' })
    hook._trigger('payment_redirect_open_tab', { url: 'https://stripe/new' })

    expect(openSpy).toHaveBeenCalledTimes(2)
    expect(openSpy).toHaveBeenNthCalledWith(
      2,
      'https://stripe/new',
      '_blank',
      'noopener,noreferrer'
    )
  })

  test('swallows a window.open exception (pop-up blocker, sandboxed iframe, …)', () => {
    openSpy.mockImplementation(() => {
      throw new Error('Pop-ups blocked')
    })
    const hook = createHookInstance()
    PaymentRedirectOpenTab.mounted.call(hook)

    expect(() =>
      hook._trigger('payment_redirect_open_tab', {
        url: 'https://checkout.stripe.com/cs_BLOCK',
      })
    ).not.toThrow()
  })
})
