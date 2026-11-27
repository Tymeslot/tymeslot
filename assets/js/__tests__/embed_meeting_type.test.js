/**
 * A host site opens one meeting type with its slug (`data-meeting-type`, or
 * `options.meetingType`): embed.js adds it to the frame's address as one more
 * segment, and the booking page sends it on to the page the type is booked
 * under.
 *
 * A file of its own because the inline snippet is read once, when embed.js
 * runs: the container has to exist before the script is evaluated.
 */

import { beforeAll, beforeEach, describe, expect, test, vi } from 'vitest'
import { readFileSync } from 'fs'
import { resolve, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))

const framePath = (root) => new URL(root.querySelector('iframe').src).pathname

beforeAll(() => {
  document.body.innerHTML = `
    <div id="tymeslot-booking" data-username="joern" data-meeting-type="intro-call"></div>
    <div data-tymeslot-inline="joern/coaching" data-meeting-type="deep-dive" id="on-page"></div>
  `
  const src = readFileSync(resolve(__dirname, '../embed.js'), 'utf-8')
  // eslint-disable-next-line no-eval
  eval(src)
})

describe('inline snippet', () => {
  test('opens the type under the username', () => {
    expect(framePath(document.getElementById('tymeslot-booking'))).toBe('/joern/intro-call')
  })

  test('opens the type under a booking page', () => {
    expect(framePath(document.getElementById('on-page'))).toBe('/joern/coaching/deep-dive')
  })
})

describe('the JavaScript API', () => {
  beforeEach(() => {
    document.getElementById('tymeslot-modal')?.remove()
    document.getElementById('tymeslot-floating-button')?.remove()
    document.getElementById('booking-container')?.remove()
  })

  test('open() takes it from options.meetingType', () => {
    window.TymeslotBooking.open('joern', { meetingType: 'intro-call' })

    expect(framePath(document.getElementById('tymeslot-modal'))).toBe('/joern/intro-call')
  })

  test('the floating button hands its options.meetingType to the popup', () => {
    window.TymeslotBooking.initFloating('joern', { meetingType: 'intro-call' })
    document.getElementById('tymeslot-floating-button').click()

    expect(framePath(document.getElementById('tymeslot-modal'))).toBe('/joern/intro-call')
  })

  test('embed() reads it from the container when the options carry none', () => {
    const container = document.createElement('div')
    container.id = 'booking-container'
    container.setAttribute('data-meeting-type', 'intro-call')
    document.body.appendChild(container)

    window.TymeslotBooking.embed('#booking-container', 'joern')

    expect(framePath(container)).toBe('/joern/intro-call')
  })

  test('the slug is escaped as one segment', () => {
    window.TymeslotBooking.open('joern', { meetingType: 'intro call?x=1' })

    expect(framePath(document.getElementById('tymeslot-modal'))).toBe('/joern/intro%20call%3Fx%3D1')
  })

  test('a slug with a slash is refused, and the page opens on its overview', () => {
    const error = vi.spyOn(console, 'error').mockImplementation(() => {})

    window.TymeslotBooking.open('joern', { meetingType: '../admin' })

    expect(framePath(document.getElementById('tymeslot-modal'))).toBe('/joern')
    expect(error).toHaveBeenCalledWith(expect.stringContaining('meetingType'), '../admin')
    error.mockRestore()
  })
})
