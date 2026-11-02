/**
 * Brings an element to the top of the view when what follows it is out of
 * sight, for a part of the page that opens in answer to the visitor's own
 * action: a moment heading that takes the focus as its moment opens
 * (`Journey.Components.moment_heading/1`), Paper's details part once a time
 * is picked, and Folio's times once a day is picked.
 *
 * `JS.focus()` scrolls only as far as the focused element itself: on a phone
 * or in a modal embed a heading lands anywhere from the middle to the bottom
 * edge, with little or none of the form under it in view. The template
 * dispatches the request after the focus:
 *
 *     JS.dispatch("tymeslot:reveal", to: "#heading", detail: %{until: "#first-field"})
 *
 * and this listener scrolls the target to the top of the view
 * (`scroll-margin-top` gives it room there) unless it is already settled:
 * the target and the element `until` names (the first field) both wholly in
 * view, and the target in the top third of the window. A layout that shows
 * them (a wide card) leaves the page where it is. It is only ever
 * dispatched from a visitor's action, never on page load, so a deep link
 * keeps its scroll position.
 *
 * Visibility comes from an IntersectionObserver, not from `innerHeight`:
 * in an inline embed the frame is as tall as the page, so only the
 * observer, which clips against the embedding page's viewport, knows what
 * the visitor sees. Its first report also arrives after LiveView has applied
 * the `JS.add_class` and `JS.focus` that go before the dispatch, so the
 * layout it measures is the one they leave.
 */

export const REVEAL_EVENT = "tymeslot:reveal"

// A target in the top third of the window is where the visitor reads on
// from; lower than that, it is brought up.
const SETTLED_SHARE = 1 / 3

function settled(target, until) {
  if (target.intersectionRatio < 1 || until.intersectionRatio < 1) return false
  return target.boundingClientRect.top <= window.innerHeight * SETTLED_SHARE
}

// How long a framed page listens for its frame resizing to the new content,
// and how long the frame must then hold its size before the check runs again.
const FRAME_RESIZE_WAIT_MS = 1000
export const FRAME_SETTLE_MS = 150

// How long a scroll cut short by the end of the document waits for the
// document to grow before it is given up.
export const GROWTH_WAIT_MS = 1000

// Ends the work an earlier reveal still has waiting (its re-check once the
// frame resizes, its finish once the document grows), so that only the
// latest request moves the page: a day picked just after a moment opened
// must not have its times carried away by the opened heading's finish.
let cancelPending = () => {}

export function revealIntoView(event) {
  const el = event.target
  if (!(el instanceof Element) || typeof IntersectionObserver === "undefined") return

  cancelPending()
  const pending = []
  cancelPending = () => pending.splice(0).forEach((cancel) => cancel())

  const selector = event.detail && event.detail.until
  const until = (selector && document.querySelector(selector)) || el

  reveal(el, until, pending)

  // An embed's frame grows to the new content only after the embedding page
  // hears of its height (iframe_embed.js), so what the first check saw may
  // be cut off by the old frame: check again once the frame has resized.
  // It grows in steps, one per height the page posts, and until the last
  // one an inline embed's page still scrolls inside a frame shorter than
  // itself, which `bringToTop` would take for a modal; so the check waits
  // for the frame to hold its size.
  if (window.self !== window.top) {
    let timer = null
    const again = () => {
      clearTimeout(timer)
      timer = setTimeout(() => reveal(el, until, pending), FRAME_SETTLE_MS)
    }
    const stop = () => {
      clearTimeout(timer)
      clearTimeout(lapse)
      window.removeEventListener("resize", again)
    }
    const lapse = setTimeout(() => window.removeEventListener("resize", again), FRAME_RESIZE_WAIT_MS)
    window.addEventListener("resize", again)
    pending.push(stop)
  }
}

// An element LiveView has removed since the request (a re-rendered moment)
// measures as a zero rect at the top of the view, which would scroll a
// framed page by its scroll margin: it is left alone.
function reveal(el, until, pending) {
  if (!el.isConnected) return

  const watched = until === el ? [el] : [el, until]
  const entries = new Map()

  const observer = new IntersectionObserver((reported) => {
    reported.forEach((entry) => entries.set(entry.target, entry))
    if (entries.size < watched.length) return

    observer.disconnect()
    if (!el.isConnected) return
    if (!settled(entries.get(el), entries.get(until))) bringToTop(el, pending)
  })

  watched.forEach((node) => observer.observe(node))
  pending.push(() => observer.disconnect())
}

// `scrollIntoView` scrolls every box between the target and the top-level
// viewport, across the frame's edge too: in a modal embed that includes the
// embedding page's frame around the iframe, which clips with overflow hidden
// and is left scrolled, cutting off the card's top and rounded corners. A
// framed page whose own document scrolls (a modal, or an inline embed with a
// capped height) therefore scrolls that document alone. Only a frame as tall
// as its page (an inline embed) needs the embedding page to scroll, and
// `scrollIntoView` is the one way across a cross-origin frame's edge.
function bringToTop(el, pending) {
  scrollToTop(el)
  finishOnceGrown(el, pending)
}

function scrollToTop(el) {
  if (window.self !== window.top && documentScrolls()) {
    window.scrollTo({ top: Math.max(topOf(el), 0), left: window.scrollX })
  } else {
    el.scrollIntoView({ block: "start", inline: "nearest" })
  }
}

// What a visitor does to scroll for themselves, which ends the wait below.
export const OWN_SCROLL_EVENTS = ["wheel", "touchstart", "keydown", "pointerdown"]

// A scroll stops at the end of the document. A part that has just opened is
// often still short of what goes under it (a continuous page's times arrive
// after its heading takes the focus), so the scroll ends short of the top,
// by however much was still to come: the target lands lower on one run than
// on the next. Each time the document grows the scroll goes on, as far as
// the new end allows, and once the target can reach the top it is finished:
// a part with little under it (a day with two times) never lets its heading
// reach the top, and still ends at the end of the page, with all of what
// arrived in view. The scroll is left as it is once the visitor has
// scrolled for themselves, the element has left the page, or a later reveal
// has taken over.
function finishOnceGrown(el, pending) {
  if (typeof ResizeObserver === "undefined" || !documentScrolls() || reachable(el)) return

  let timer = null
  let height = scrollRoot().scrollHeight
  const observer = new ResizeObserver(() => {
    if (!el.isConnected) return stop()
    if (scrollRoot().scrollHeight <= height) return
    height = scrollRoot().scrollHeight
    if (reachable(el)) stop()
    scrollToTop(el)
  })
  const stop = () => {
    observer.disconnect()
    clearTimeout(timer)
    OWN_SCROLL_EVENTS.forEach((type) => window.removeEventListener(type, stop))
  }

  observer.observe(document.documentElement)
  OWN_SCROLL_EVENTS.forEach((type) => window.addEventListener(type, stop, { passive: true }))
  timer = setTimeout(stop, GROWTH_WAIT_MS)
  pending.push(stop)
}

// Where the document must scroll to for `el` to sit at the top of the view,
// its `scroll-margin-top` above it; the same during a smooth scroll as after.
function topOf(el) {
  const margin = parseFloat(window.getComputedStyle(el).scrollMarginTop) || 0
  return window.scrollY + el.getBoundingClientRect().top - margin
}

function reachable(el) {
  return topOf(el) <= scrollRoot().scrollHeight - window.innerHeight + 1
}

function documentScrolls() {
  return scrollRoot().scrollHeight > window.innerHeight
}

function scrollRoot() {
  return document.scrollingElement || document.documentElement
}

export function installRevealIntoView(root = window) {
  root.addEventListener(REVEAL_EVENT, revealIntoView)
  return () => root.removeEventListener(REVEAL_EVENT, revealIntoView)
}
