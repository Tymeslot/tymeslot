// desktop_reminders.js
// LiveView hook: fires browser desktop notifications for the host's upcoming
// calendar events while the dashboard is open.
//
// The server renders a JSON feed of {key, fire_at_ms, title, body} entries on
// the element's data-reminders attribute (refreshed on every 60s tick) and a
// data-enabled flag from the user's preference. This hook polls and fires a
// Notification when an entry's fire instant crosses its polling window. No
// service worker / push — notifications only fire while the tab is open.

const POLL_MS = 30000
// On the first tick (and after re-enabling) look back this far so a reminder
// whose fire time *just* passed still fires, without replaying stale ones.
const INITIAL_LOOKBACK_MS = 90000

// Pure core: feed entries whose fire instant falls in (lastMs, nowMs]. The
// window is half-open so each entry fires in exactly one tick and never twice
// at a boundary. Exported for unit testing.
export function selectDue(feed, lastMs, nowMs) {
  return feed.filter((entry) => entry.fire_at_ms > lastMs && entry.fire_at_ms <= nowMs)
}

export const DesktopReminders = {
  mounted() {
    this._fired = new Set()
    this._lastCheck = null
    this._feed = this._readFeed()
    this._maybeRequestPermission()
    this._tick()
    this._timer = setInterval(() => this._tick(), POLL_MS)
  },

  updated() {
    this._feed = this._readFeed()
    this._maybeRequestPermission()
  },

  destroyed() {
    if (this._timer) clearInterval(this._timer)
  },

  _enabled() {
    return this.el.dataset.enabled === "true"
  },

  _readFeed() {
    try {
      return JSON.parse(this.el.dataset.reminders || "[]")
    } catch (_e) {
      return []
    }
  },

  _maybeRequestPermission() {
    if (!this._enabled()) return
    if (typeof Notification === "undefined") return
    if (Notification.permission !== "default") return

    const result = Notification.requestPermission()
    // Modern browsers return a promise; guard the legacy callback form.
    if (result && typeof result.catch === "function") result.catch(() => {})
  },

  _tick() {
    if (!this._enabled()) return
    if (typeof Notification === "undefined" || Notification.permission !== "granted") return

    const now = Date.now()
    const last = this._lastCheck == null ? now - INITIAL_LOOKBACK_MS : this._lastCheck

    for (const entry of selectDue(this._feed, last, now)) {
      if (this._fired.has(entry.key)) continue
      this._fired.add(entry.key)

      try {
        new Notification(entry.title, { body: entry.body, tag: entry.key })
      } catch (_e) {
        // Surface the key again so a later tick can retry the notification.
        this._fired.delete(entry.key)
      }
    }

    this._lastCheck = now
  },
}
