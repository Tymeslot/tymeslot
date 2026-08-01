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
