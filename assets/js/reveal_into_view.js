/**
 * Brings an element to the top of the view when what follows it is out of
 * sight, for a part of the page that opens in answer to the visitor's own
 * action (Paper's details part, once a time is picked).
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

// How long a page waits for its frame (or, for a scroll cut short, its
// document) to start growing to the new content, and how long a frame must
// then hold its size before the check runs again.
const FRAME_RESIZE_WAIT_MS = 1000
export const FRAME_SETTLE_MS = 150

export function revealIntoView(event) {
  const el = event.target
  if (!(el instanceof Element) || typeof IntersectionObserver === "undefined") return

  const selector = event.detail && event.detail.until
  const until = (selector && document.querySelector(selector)) || el

  reveal(el, until)

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
      timer = setTimeout(() => reveal(el, until), FRAME_SETTLE_MS)
    }
    window.addEventListener("resize", again)
    setTimeout(() => window.removeEventListener("resize", again), FRAME_RESIZE_WAIT_MS)
  }
}

function reveal(el, until) {
  const watched = until === el ? [el] : [el, until]
  const entries = new Map()

  const observer = new IntersectionObserver((reported) => {
    reported.forEach((entry) => entries.set(entry.target, entry))
    if (entries.size < watched.length) return

    observer.disconnect()
    if (!settled(entries.get(el), entries.get(until))) bringToTop(el)
  })

  watched.forEach((node) => observer.observe(node))
}

// `scrollIntoView` scrolls every box between the target and the top-level
// viewport, across the frame's edge too: in a modal embed that includes the
// embedding page's frame around the iframe, which clips with overflow hidden
// and is left scrolled, cutting off the card's top and rounded corners. A
// framed page whose own document scrolls (a modal, or an inline embed with a
// capped height) therefore scrolls that document alone. Only a frame as tall
// as its page (an inline embed) needs the embedding page to scroll, and
// `scrollIntoView` is the one way across a cross-origin frame's edge.
function bringToTop(el) {
  scrollToTop(el)
  finishOnceGrown(el)
}

function scrollToTop(el) {
  if (window.self !== window.top && documentScrolls()) {
    window.scrollTo({ top: Math.max(topOf(el), 0), left: window.scrollX })
  } else {
    el.scrollIntoView({ block: "start", inline: "nearest" })
  }
}

// What a visitor does to scroll for themselves, which ends the wait below.
const OWN_SCROLL_EVENTS = ["wheel", "touchstart", "keydown"]

// A scroll stops at the end of the document. A part that has just opened is
// often still short of what goes under it (a continuous page's times arrive
// after its heading takes the focus), so the scroll ends short of the top,
// by however much was still to come: the target lands lower on one run than
// on the next. When the document has grown enough, the scroll is finished,
// unless the visitor has scrolled for themselves in the meantime.
function finishOnceGrown(el) {
  if (typeof ResizeObserver === "undefined" || !documentScrolls() || reachable(el)) return

  let timer = null
  const observer = new ResizeObserver(() => {
    if (!reachable(el)) return
    stop()
    scrollToTop(el)
  })
  const stop = () => {
    observer.disconnect()
    clearTimeout(timer)
    OWN_SCROLL_EVENTS.forEach((type) => window.removeEventListener(type, stop))
  }

  observer.observe(document.documentElement)
  OWN_SCROLL_EVENTS.forEach((type) => window.addEventListener(type, stop, { passive: true }))
  timer = setTimeout(stop, FRAME_RESIZE_WAIT_MS)
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
