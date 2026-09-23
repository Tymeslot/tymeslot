/**
 * Vendor-neutral analytics facade + LiveView event bridge.
 *
 * `window.analytics.track(event, props)` is the only surface call sites use.
 * The current sink is Umami — this file is the ONLY place that knows that.
 * When no analytics script is loaded (standalone Core with no UMAMI_* env),
 * track() is a safe no-op, so Core behaves identically with or without analytics.
 *
 * GDPR guardrail: props must be categorical dimensions only (e.g. {step}).
 * Never pass user ids, emails, names, or free text.
 */

/**
 * Events tracked before the provider arrives are buffered rather than dropped.
 * The tracker is injected from an idle callback after `load` (see
 * `analytics_scripts/1` in `layouts.ex`), which lands after LiveView mounts —
 * so the page-view beacons that fire on mount would otherwise be lost.
 * The cap keeps the buffer bounded on a standalone Core install, where no
 * provider ever arrives and the queue would grow for the life of the page.
 */
const PENDING_LIMIT = 50;

/**
 * Name of the global the tracker calls before sending anything. The loader in
 * `analytics_scripts/1` (`layouts.ex`) passes it to Umami as `data-before-send`
 * and refuses to load the tracker at all when it is missing, so an unscrubbed
 * address can never be sent.
 */
export const BEFORE_SEND_GLOBAL = "tymeslotAnalyticsBeforeSend";

// A meeting's uid is the only credential its cancel and reschedule links carry:
// whoever holds `/:username/meeting/<uid>/cancel` can cancel that meeting. Keep
// the page recognisable, drop the credential.
const MEETING_UID_SEGMENT = /\/meeting\/[^/]+/g;

// Query strings carry identifiers too (`?reschedule_meeting_uid=`, and names or
// emails on older confirmation links), so only campaign tags survive.
const KEPT_QUERY_PARAM = /^utm_[a-z]+$/;

/**
 * Removes credentials and personal data from an address before it reaches the
 * analytics store: meeting uids in the path, every query parameter except
 * `utm_*` campaign tags, and the fragment. Accepts absolute URLs and the
 * origin-relative paths Umami sends as the referrer; anything that does not
 * parse is returned unchanged.
 */
export function scrubAnalyticsUrl(value) {
  if (typeof value !== "string" || value === "") return value;

  let url;
  try {
    url = new URL(value, "https://relative.invalid");
  } catch (_e) {
    return value;
  }

  url.pathname = url.pathname.replace(MEETING_UID_SEGMENT, "/meeting/:uid");
  for (const key of [...url.searchParams.keys()]) {
    if (!KEPT_QUERY_PARAM.test(key)) url.searchParams.delete(key);
  }
  url.hash = "";

  const absolute = /^[a-z][a-z0-9+.-]*:|^\/\//i.test(value);
  return absolute ? url.toString() : `${url.pathname}${url.search}`;
}

/** Umami `before-send` callback: scrubs the page and referrer addresses of every payload. */
export function scrubAnalyticsPayload(_type, payload) {
  if (!payload || typeof payload !== "object") return payload;
  return {
    ...payload,
    url: scrubAnalyticsUrl(payload.url),
    referrer: scrubAnalyticsUrl(payload.referrer),
  };
}

export function installAnalytics(target = window) {
  const pending = [];

  const provider = () => {
    const candidate = target.umami;
    return candidate && typeof candidate.track === "function" ? candidate : null;
  };

  const flush = () => {
    const sink = provider();
    if (!sink) return;
    while (pending.length) {
      const [event, props] = pending.shift();
      sink.track(event, props);
    }
  };

  target.analytics = {
    track(event, props = {}) {
      const sink = provider();
      if (sink) {
        flush();
        sink.track(event, props);
      } else if (pending.length < PENDING_LIMIT) {
        pending.push([event, props]);
      }
    },
  };

  target[BEFORE_SEND_GLOBAL] = scrubAnalyticsPayload;
  target.addEventListener?.("tymeslot:analytics-ready", flush);
  return target.analytics;
}

/**
 * Capture-phase delegated click handler. Any element (or ancestor) with
 * `data-analytics-event` fires analytics.track when clicked.
 * Optional `data-analytics-props` holds a JSON object of categorical
 * dimensions — never user ids, emails, or free text (GDPR guardrail).
 * Safe no-op when no analytics provider is present.
 */
export function installClickTracking(target = window, root = document) {
  root.addEventListener(
    "click",
    (event) => {
      const el = event.target.closest?.("[data-analytics-event]");
      if (!el) return;
      const name = el.dataset.analyticsEvent;
      let props = {};
      const raw = el.dataset.analyticsProps;
      if (raw) {
        try {
          props = JSON.parse(raw);
        } catch (_e) {
          props = {};
        }
      }
      target.analytics?.track(name, props);
    },
    true,
  );
}

/**
 * LiveView hook that fires a single analytics event when its element is mounted
 * on the connected client — the "view" counterpart to the click handler above.
 * Reads `data-analytics-event` and optional `data-analytics-props` (a JSON object
 * of categorical dimensions — never user ids, emails, or free text). Use on a
 * hidden beacon element to record a page impression. Re-runs on each LiveView
 * mount (including live navigation); never fires on the static/dead render.
 * Safe no-op when no analytics provider is present.
 */
export const AnalyticsView = {
  mounted() {
    const name = this.el.dataset.analyticsEvent;
    if (!name) return;
    let props = {};
    const raw = this.el.dataset.analyticsProps;
    if (raw) {
      try {
        props = JSON.parse(raw);
      } catch (_e) {
        props = {};
      }
    }
    window.analytics?.track(name, props);
  },
};

/**
 * Bridges server-pushed events to the facade. LiveView's
 * `push_event(socket, "ts:analytics", %{name, props})` is dispatched on the
 * window as `phx:ts:analytics`; forward it to analytics.track.
 */
export function installEventBridge(target = window) {
  target.addEventListener("phx:ts:analytics", (event) => {
    const detail = event.detail || {};
    if (detail.name && target.analytics) {
      target.analytics.track(detail.name, detail.props || {});
    }
  });
}
