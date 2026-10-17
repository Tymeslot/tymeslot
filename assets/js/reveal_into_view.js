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
 * and this listener scrolls the target to the top of its scrolling box
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

// How long an embedded page waits for its frame to grow to the new content.
const FRAME_RESIZE_WAIT_MS = 1000

export function revealIntoView(event) {
  const el = event.target
  if (!(el instanceof Element) || typeof IntersectionObserver === "undefined") return

  const selector = event.detail && event.detail.until
  const until = (selector && document.querySelector(selector)) || el

  reveal(el, until)

  // An embed's frame grows to the new content only after the embedding page
  // hears of its height (iframe_embed.js), so what the first check saw may
  // be cut off by the old frame: check again once the frame has resized.
  if (window.self !== window.top) {
    const again = () => {
      window.removeEventListener("resize", again)
      reveal(el, until)
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
    if (!settled(entries.get(el), entries.get(until))) {
      el.scrollIntoView({ block: "start", inline: "nearest" })
    }
  })

  watched.forEach((node) => observer.observe(node))
}

export function installRevealIntoView(root = window) {
  root.addEventListener(REVEAL_EVENT, revealIntoView)
  return () => root.removeEventListener(REVEAL_EVENT, revealIntoView)
}
