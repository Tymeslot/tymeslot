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

// Longest value kept per key, mirroring the booking form's own limits
// (NameValidator 100, EmailValidator 254 characters). A longer value would be
// refused on submit anyway, and carrying it in the connect params makes the
// websocket URL too long to open, leaving the page without a live connection.
const PREFILL_LIMITS = { name: 100, email: 254 }
const PREFILL_KEYS = Object.keys(PREFILL_LIMITS)

// Counted in code points, as the server counts characters.
const withinLimit = (value, limit) => value.length <= limit || [...value].length <= limit

// Decodes one fragment component. A fragment is not form-encoded, so a
// literal `+` stays a `+` (`ada+test@example.com`), unlike in
// URLSearchParams, which would turn it into a space. Returns null for a
// malformed escape.
const decode = (raw) => {
  try {
    return decodeURIComponent(raw)
  } catch {
    return null
  }
}

/**
 * Reads the prefill keys from the fragment and strips them from the URL,
 * leaving any other fragment content in place, byte for byte.
 *
 * @returns {Object} the non-empty prefill values within their length limit, keyed by name; `{}` when the
 *   fragment carries none, in which case the URL is left untouched
 */
export function takeAttendeePrefill(loc = window.location, hist = window.history) {
  if (!loc.hash || loc.hash.length < 2) return {}

  const segments = loc.hash.slice(1).split("&")
  const keyOf = (segment) => decode(segment.split("=", 1)[0])
  if (!segments.some(segment => PREFILL_KEYS.includes(keyOf(segment)))) return {}

  const prefill = {}
  const seen = new Set()
  const rest = []
  for (const segment of segments) {
    const key = keyOf(segment)
    if (!PREFILL_KEYS.includes(key)) {
      if (segment) rest.push(segment)
      continue
    }
    if (seen.has(key)) continue
    seen.add(key)
    const eq = segment.indexOf("=")
    const value = eq === -1 ? "" : decode(segment.slice(eq + 1))
    if (value && withinLimit(value, PREFILL_LIMITS[key])) prefill[key] = value
  }

  const remaining = rest.join("&")
  hist.replaceState(hist.state, "", loc.pathname + loc.search + (remaining ? `#${remaining}` : ""))

  return prefill
}
