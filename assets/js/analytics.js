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
export function installAnalytics(target = window) {
  target.analytics = {
    track(event, props = {}) {
      const provider = target.umami;
      if (provider && typeof provider.track === "function") {
        provider.track(event, props);
      }
    },
  };
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
