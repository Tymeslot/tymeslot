/**
 * Attendee prefill from a booking link's URL fragment.
 *
 * `/:username#name=Ada%20Lovelace&email=ada%40example.com` opens the booking
 * page with the booking form's name and email already filled in, so an
 * organiser booking on someone's behalf can generate the link from the record
 * they already hold.
 *
 * The values travel in the fragment because a browser never sends it to the
 * server: they stay out of access logs and Referer headers. They are read
 * once, on page load, and removed from the address bar, so the page's history
 * entry and any link copied from it no longer carry them. The LiveView
 * receives them in its connect params, and the server decides what to use.
 */

const PREFILL_KEYS = ["name", "email"]

/**
 * Reads the prefill keys from the fragment and strips them from the URL,
 * leaving any other fragment content in place.
 *
 * @returns {Object} the non-empty prefill values, keyed by name; `{}` when the
 *   fragment carries none, in which case the URL is left untouched
 */
export function takeAttendeePrefill(loc = window.location, hist = window.history) {
  if (!loc.hash || loc.hash.length < 2) return {}

  const params = new URLSearchParams(loc.hash.slice(1))
  if (!PREFILL_KEYS.some(key => params.has(key))) return {}

  const prefill = {}
  for (const key of PREFILL_KEYS) {
    const value = params.get(key)
    if (value) prefill[key] = value
    params.delete(key)
  }

  const rest = params.toString()
  hist.replaceState(hist.state, "", loc.pathname + loc.search + (rest ? `#${rest}` : ""))

  return prefill
}
