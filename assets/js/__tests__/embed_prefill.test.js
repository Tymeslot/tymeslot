/**
 * The visitor details a host site hands embed.js (`data-prefill-name`,
 * `data-prefill-email`, or `options.prefill`) reach the booking page in the
 * iframe's fragment, which the page reads (attendee_prefill.js) and a
 * browser never sends to a server.
 *
 * A file of its own because the inline snippet is read once, when embed.js
 * runs: the container has to exist before the script is evaluated.
 */

import { beforeAll, beforeEach, describe, expect, test } from 'vitest'
import { readFileSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))

const frameUrl = (root) => new URL(root.querySelector('iframe').src)

beforeAll(() => {
  document.body.innerHTML = `
    <div id="tymeslot-booking" data-username="joern/coaching/deep-dive"
         data-prefill-name="Zoë O'Neil" data-prefill-email="zoe+crm@example.com"
         data-prefill-phone="+44 20 7946 0000"></div>
  `
  const src = readFileSync(resolve(__dirname, '../embed.js'), 'utf-8')
  // eslint-disable-next-line no-eval
  eval(src)
})

describe('inline snippet', () => {
  test('carries name and email in the fragment, each one encoded', () => {
    const url = frameUrl(document.getElementById('tymeslot-booking'))

    expect(url.hash).toBe('#name=Zo%C3%AB%20O\'Neil&email=zoe%2Bcrm%40example.com')
  })

  test('keeps them out of the query the server receives', () => {
    const url = frameUrl(document.getElementById('tymeslot-booking'))

    expect(url.searchParams.has('name')).toBe(false)
    expect(url.searchParams.has('email')).toBe(false)
    expect(url.searchParams.get('embed')).toBe('1')
  })

  test('forwards no other data-prefill-* attribute', () => {
    const url = frameUrl(document.getElementById('tymeslot-booking'))

    expect(url.hash).not.toContain('phone')
  })

  test('opens a meeting type under a page at its three-part address', () => {
    const url = frameUrl(document.getElementById('tymeslot-booking'))

    expect(url.pathname).toBe('/joern/coaching/deep-dive')
  })
})

describe('the JavaScript API', () => {
  beforeEach(() => {
    document.getElementById('tymeslot-modal')?.remove()
    document.getElementById('tymeslot-floating-button')?.remove()
    document.getElementById('booking-container')?.remove()
  })

  test('open() takes them from options.prefill', () => {
    window.TymeslotBooking.open('alice', { prefill: { name: 'Ann Lee', email: 'ann@example.com' } })

    expect(frameUrl(document.getElementById('tymeslot-modal')).hash)
      .toBe('#name=Ann%20Lee&email=ann%40example.com')
  })

  test('open() leaves out a blank or non-text value, and any other key', () => {
    window.TymeslotBooking.open('alice', {
      prefill: { name: '  ', email: 42, message: 'hello' }
    })

    expect(frameUrl(document.getElementById('tymeslot-modal')).hash).toBe('')
  })

  test('the floating button hands its options.prefill to the popup', () => {
    window.TymeslotBooking.initFloating('alice', { prefill: { email: 'ann@example.com' } })
    document.getElementById('tymeslot-floating-button').click()

    expect(frameUrl(document.getElementById('tymeslot-modal')).hash).toBe('#email=ann%40example.com')
  })

  test('embed() reads them from the container when the options carry none', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    container.setAttribute('data-prefill-name', 'Ann Lee')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'alice')

    expect(frameUrl(container).hash).toBe('#name=Ann%20Lee')
  })
})
