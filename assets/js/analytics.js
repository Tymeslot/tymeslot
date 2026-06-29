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
 * LiveView hook for the homepage hero "booking demo" media.
 *
 * Both the poster `<img>` (phones) and the autoplaying `<video>` (desktop) carry
 * this hook, but only one is rendered per breakpoint — Tailwind's `lg:hidden` /
 * `hidden lg:block` sets `display:none` on the other, so its `offsetParent` is
 * null. The visibility guard reports `hero_demo_viewed` from exactly the element
 * the visitor actually sees, so video and poster never double-count.
 *
 * The desktop video plays through once (no loop). When it ends, the hook reveals
 * the real CTA (`data-cta-target`) and reports `hero_demo_completed`. If autoplay
 * is blocked, the CTA is revealed immediately so it is never stranded behind a
 * video that will not play — but completion is not reported, since the demo was
 * not watched. The mobile poster has no video, so its CTA stays visible from the
 * start (the markup hides the CTA only at the `lg` breakpoint).
 *
 * Reads `data-analytics-event` / `data-analytics-props` like AnalyticsView; the
 * props are categorical only (variant/surface — no ids or free text). Safe
 * no-op when no analytics provider is present.
 */
export const HeroDemo = {
  mounted() {
    if (this.el.offsetParent === null) return;

    let props = {};
    const raw = this.el.dataset.analyticsProps;
    if (raw) {
      try {
        props = JSON.parse(raw);
      } catch (_e) {
        props = {};
      }
    }

    const name = this.el.dataset.analyticsEvent;
    if (name) window.analytics?.track(name, props);

    if (this.el.tagName !== "VIDEO") return;

    this._onEnded = () => {
      this.revealCta();
      window.analytics?.track("hero_demo_completed", { surface: props.surface });
    };
    this.el.addEventListener("ended", this._onEnded, { once: true });

    const playing = this.el.play?.();
    if (playing && typeof playing.catch === "function") {
      playing.catch(() => this.revealCta());
    }
  },

  revealCta() {
    const cta = document.getElementById(this.el.dataset.ctaTarget);
    if (!cta) return;
    // Inline styles override the markup's `lg:opacity-0` / `lg:pointer-events-none`.
    cta.style.opacity = "1";
    cta.style.pointerEvents = "auto";
  },

  destroyed() {
    if (this._onEnded) this.el.removeEventListener("ended", this._onEnded);
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
