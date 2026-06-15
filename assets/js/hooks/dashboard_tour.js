/**
 * DashboardTour
 *
 * Positions a spotlight + tooltip over the dashboard element whose
 * `data-tour` attribute matches the current step's `data-anchor`.
 *
 * State (current step, content) lives in the LiveView. This hook only:
 *   - gates on viewport size (>= 1024px)
 *   - locates the anchor element (with a short retry for late-loading DOM)
 *   - sizes the spotlight div over the anchor's bounding rect (+padding)
 *   - places the tooltip per `data-placement`
 *   - keeps both elements in sync on resize and scroll
 */
const ANCHOR_RETRY_MS = 100;
const ANCHOR_RETRY_TIMEOUT_MS = 1000;
const SPOTLIGHT_PADDING_PX = 8;
const TOOLTIP_GAP_PX = 12;
const MIN_VIEWPORT_PX = 1024;

export const DashboardTour = {
  mounted() {
    if (this.viewportTooSmall()) {
      this.pushEvent("tour:viewport-too-small", {});
      return;
    }

    this.pushEvent("tour:shown", {});

    // Seed the step cache so the first real step change (not the initial paint,
    // which the overlay's CSS fade-in already covers) triggers a per-step fade.
    this.lastStepIndex = this.el.dataset.stepIndex;

    this.onResize = () => {
      if (this.viewportTooSmall()) {
        this.pushEvent("tour:viewport-too-small", {});
        return;
      }
      this.position();
    };
    this.onScroll = () => this.position();
    window.addEventListener("resize", this.onResize, { passive: true });
    window.addEventListener("scroll", this.onScroll, { passive: true, capture: true });

    this.position({ scroll: true });
  },

  updated() {
    const anchor = this.el.dataset.anchor;
    const placement = this.el.dataset.placement || "bottom";
    const stepIndex = this.el.dataset.stepIndex;

    const stepChanged = stepIndex !== this.lastStepIndex;
    const layoutUnchanged = anchor === this.lastAnchor && placement === this.lastPlacement;

    // Ignore unrelated LiveView patches: neither the step nor its anchor moved.
    if (!stepChanged && layoutUnchanged) return;

    if (stepChanged) {
      this.lastStepIndex = stepIndex;
      this.beginStepEnter();
    }

    this.position({ scroll: true });
  },

  // Hide the card instantly (no transition) so the new step's content does not
  // flash in at the old position. finishStepEnter() releases it once positioned.
  beginStepEnter() {
    this.stepEntering = true;
    const tooltip = this.el.querySelector(".dashboard-tour__tooltip");
    if (tooltip) tooltip.classList.add("is-entering");
  },

  finishStepEnter() {
    if (!this.stepEntering) return;
    this.stepEntering = false;
    const tooltip = this.el.querySelector(".dashboard-tour__tooltip");
    if (!tooltip) return;
    // Next frame: drop `is-entering` so the opacity transition fades the card in.
    requestAnimationFrame(() => tooltip.classList.remove("is-entering"));
  },

  destroyed() {
    if (this.anchorInterval) {
      clearInterval(this.anchorInterval);
      this.anchorInterval = null;
    }
    if (this.rafId) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }
    if (this.onResize) {
      window.removeEventListener("resize", this.onResize);
      window.removeEventListener("scroll", this.onScroll, { capture: true });
    }
  },

  viewportTooSmall() {
    return !window.matchMedia(`(min-width: ${MIN_VIEWPORT_PX}px)`).matches;
  },

  position({ scroll = false } = {}) {
    if (this.anchorInterval) {
      clearInterval(this.anchorInterval);
      this.anchorInterval = null;
    }
    if (this.rafId) {
      cancelAnimationFrame(this.rafId);
      this.rafId = null;
    }

    const anchor = this.el.dataset.anchor;
    const placement = this.el.dataset.placement || "bottom";

    if (!anchor) {
      this.applyCenteredLayout();
      return Promise.resolve();
    }

    return this.findAnchor(anchor)
      .then((target) => this.applySpotlightLayout(target, placement, scroll))
      .catch(() => this.pushEvent("tour:skip-step", {}));
  },

  findAnchor(anchorName) {
    return new Promise((resolve, reject) => {
      const selector = `[data-tour="${anchorName}"]`;
      const found = document.querySelector(selector);
      if (found) {
        resolve(found);
        return;
      }

      const start = Date.now();
      this.anchorInterval = setInterval(() => {
        const el = document.querySelector(selector);
        if (el) {
          clearInterval(this.anchorInterval);
          this.anchorInterval = null;
          resolve(el);
        } else if (Date.now() - start > ANCHOR_RETRY_TIMEOUT_MS) {
          clearInterval(this.anchorInterval);
          this.anchorInterval = null;
          reject(new Error(`anchor "${anchorName}" not found`));
        }
      }, ANCHOR_RETRY_MS);
    });
  },

  applyCenteredLayout() {
    const backdrop = this.el.querySelector(".dashboard-tour__backdrop");
    const spotlight = this.el.querySelector(".dashboard-tour__spotlight");
    const tooltip = this.el.querySelector(".dashboard-tour__tooltip");
    if (!spotlight || !tooltip) return;

    if (backdrop) backdrop.style.display = "block";
    spotlight.style.display = "none";

    tooltip.style.position = "fixed";
    tooltip.style.left = "50%";
    tooltip.style.top = "50%";
    tooltip.style.transform = "translate(-50%, -50%)";

    // Record that we are now on a centered (anchorless) step. Without this the
    // cache keeps the previous anchored step's anchor/placement, so navigating
    // Back to centered then forward to the *same* anchored step would trip the
    // early-return in updated() and leave the spotlight unpositioned.
    this.lastAnchor = this.el.dataset.anchor;
    this.lastPlacement = this.el.dataset.placement || "bottom";
    this.finishStepEnter();
  },

  applySpotlightLayout(target, placement, scroll) {
    const backdrop = this.el.querySelector(".dashboard-tour__backdrop");
    const spotlight = this.el.querySelector(".dashboard-tour__spotlight");
    const tooltip = this.el.querySelector(".dashboard-tour__tooltip");
    if (!spotlight || !tooltip) return;

    if (backdrop) backdrop.style.display = "none";

    if (scroll) {
      target.scrollIntoView({ block: "center", inline: "center", behavior: "smooth" });
    }

    // Use an animation frame so the scroll has at least begun before measuring.
    this.rafId = requestAnimationFrame(() => {
      this.rafId = null;
      const rect = target.getBoundingClientRect();

      spotlight.style.display = "block";
      spotlight.style.position = "fixed";
      spotlight.style.top = `${rect.top - SPOTLIGHT_PADDING_PX}px`;
      spotlight.style.left = `${rect.left - SPOTLIGHT_PADDING_PX}px`;
      spotlight.style.width = `${rect.width + SPOTLIGHT_PADDING_PX * 2}px`;
      spotlight.style.height = `${rect.height + SPOTLIGHT_PADDING_PX * 2}px`;

      this.placeTooltip(tooltip, rect, placement);
      this.lastAnchor = this.el.dataset.anchor;
      this.lastPlacement = this.el.dataset.placement || "bottom";
      this.finishStepEnter();
    });
  },

  placeTooltip(tooltip, rect, placement) {
    tooltip.style.position = "fixed";
    tooltip.style.transform = "none";

    switch (placement) {
      case "top":
        tooltip.style.top = `${rect.top - TOOLTIP_GAP_PX}px`;
        tooltip.style.left = `${rect.left + rect.width / 2}px`;
        tooltip.style.transform = "translate(-50%, -100%)";
        break;
      case "left":
        tooltip.style.top = `${rect.top + rect.height / 2}px`;
        tooltip.style.left = `${rect.left - TOOLTIP_GAP_PX}px`;
        tooltip.style.transform = "translate(-100%, -50%)";
        break;
      case "right":
        tooltip.style.top = `${rect.top + rect.height / 2}px`;
        tooltip.style.left = `${rect.right + TOOLTIP_GAP_PX}px`;
        tooltip.style.transform = "translate(0, -50%)";
        break;
      case "bottom_end":
        tooltip.style.top = `${rect.bottom + TOOLTIP_GAP_PX}px`;
        tooltip.style.left = `${rect.right}px`;
        tooltip.style.transform = "translate(-100%, 0)";
        break;
      case "bottom":
      default:
        tooltip.style.top = `${rect.bottom + TOOLTIP_GAP_PX}px`;
        tooltip.style.left = `${rect.left + rect.width / 2}px`;
        tooltip.style.transform = "translate(-50%, 0)";
        break;
    }
  },
};
