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
