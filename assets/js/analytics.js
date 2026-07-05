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
 * LiveView hook for the homepage hero "booking demo" <video>.
 *
 * Playback is gated on visibility: an IntersectionObserver starts the single
 * play (no loop) only once the video scrolls into view, so a visitor who meets
 * it stacked below the hero text on a phone still watches from the first frame
 * rather than arriving after an on-mount autoplay has already ended. The same
 * moment reports `hero_demo_viewed`. Where IntersectionObserver is unavailable
 * the hook starts immediately, matching the old behaviour.
 *
 * The video plays through once. When it ends, the hook reveals the real CTA
 * (`data-cta-target`) and reports `hero_demo_completed`. If playback is blocked,
 * the CTA is revealed immediately so it is never stranded behind a video that
 * will not play — but completion is not reported, since the demo was not watched.
 *
 * Reads `data-analytics-event` / `data-analytics-props` like AnalyticsView; the
 * props are categorical only (variant/surface — no ids or free text). Safe
 * no-op when no analytics provider is present.
 */
export const HeroDemo = {
  mounted() {
    let props = {};
    const raw = this.el.dataset.analyticsProps;
    if (raw) {
      try {
        props = JSON.parse(raw);
      } catch (_e) {
        props = {};
      }
    }

    this._onEnded = () => {
      this.revealCta();
      window.analytics?.track("hero_demo_completed", { surface: props.surface });
    };
    this.el.addEventListener("ended", this._onEnded, { once: true });

    // Report the view and begin the single play the moment the video enters the
    // viewport — not on mount — so it is never already over by the time a mobile
    // visitor scrolls down to it.
    const start = () => {
      const name = this.el.dataset.analyticsEvent;
      if (name) window.analytics?.track(name, props);

      const playing = this.el.play?.();
      if (playing && typeof playing.catch === "function") {
        playing.catch(() => this.revealCta());
      }
    };

    if (typeof IntersectionObserver !== "function") {
      start();
      return;
    }

    this._observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        this._observer.disconnect();
        this._observer = null;
        start();
      },
      { threshold: 0.25 },
    );
    this._observer.observe(this.el);
  },

  revealCta() {
    const cta = document.getElementById(this.el.dataset.ctaTarget);
    if (!cta) return;
    // Inline styles override the markup's `opacity-0` / `pointer-events-none`.
    cta.style.opacity = "1";
    cta.style.pointerEvents = "auto";
  },

  destroyed() {
    if (this._onEnded) this.el.removeEventListener("ended", this._onEnded);
    if (this._observer) this._observer.disconnect();
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
