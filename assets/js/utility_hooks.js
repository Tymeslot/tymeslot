// Utility hooks for LiveView
// Handles general utility functions like flash messages, scrolling, and focus

// Flash message hook for auto-dismiss functionality
export const Flash = {
  mounted() {
    // Auto-dismiss after 6 seconds
    this.timer = setTimeout(() => {
      if (this.el.dataset.close !== "false") {
        this.el.click();
      }
    }, 6000);
    
    // Trigger mounted event for additional handling if needed
    window.dispatchEvent(new CustomEvent("flash:mounted", { 
      detail: { id: this.el.id } 
    }));
  },
  
  destroyed() {
    clearTimeout(this.timer);
  }
};

// Connection status hook for LiveView disconnects.
// Shows the "Attempting to reconnect" toast on LiveView disconnects.
//
// We intentionally suppress it only for explicit OAuth link clicks (Google/GitHub),
// to avoid showing it while leaving the page, without masking real disconnects.
export const ConnectionStatus = {
  mounted() {
    this.showDelayMs = 5000;
    this.isDisconnected = false;
    this.pendingShowOnVisible = false;
    this.suppressedShowTimer = null;
    this.delayedShowTimer = null;
    this.hideTimer = null;

    // Ensure we start hidden (server renders with display: none)
    this.el.style.display = "none";
    this.el.classList.add("opacity-0", "translate-x-8");
    this.el.classList.remove("opacity-100", "translate-x-0");

    this.getSuppressUntil = () => {
      const v = window.__tymeslot_suppress_lv_disconnect_until;
      return typeof v === "number" ? v : 0;
    };

    this.isSuppressed = () => Date.now() < this.getSuppressUntil();

    this.scheduleShow = (delayMs) => {
      const delay = Math.max(0, delayMs);
      this.delayedShowTimer = setTimeout(() => {
        if (!this.isDisconnected) return;
        if (this.isSuppressed()) return;
        if (document.visibilityState === "hidden") {
          this.pendingShowOnVisible = true;
          return;
        }
        this.show();
      }, delay);
    };

    this.onVisibilityChange = () => {
      if (document.visibilityState !== "visible") return;
      if (!this.pendingShowOnVisible) return;
      this.pendingShowOnVisible = false;
      if (!this.isDisconnected) return;
      if (this.isSuppressed()) return;
      this.show();
    };

    this.onDisconnected = () => {
      this.isDisconnected = true;

      // If the user intentionally initiated an OAuth navigation, suppress
      // the toast briefly. If we're *still* disconnected after the suppression
      // window, show it (this preserves real issue visibility).
      clearTimeout(this.suppressedShowTimer);
      clearTimeout(this.delayedShowTimer);
      this.pendingShowOnVisible = false;

      if (this.isSuppressed()) {
        const delay = Math.max(0, this.getSuppressUntil() - Date.now()) + 10;
        this.suppressedShowTimer = setTimeout(() => {
          if (!this.isDisconnected) return;
          if (this.isSuppressed()) return;
          this.scheduleShow(this.showDelayMs);
        }, delay);

        return;
      }

      if (document.visibilityState === "hidden") return;
      this.scheduleShow(this.showDelayMs);
    };

    this.onConnected = () => {
      this.isDisconnected = false;
      clearTimeout(this.suppressedShowTimer);
      clearTimeout(this.delayedShowTimer);
      this.pendingShowOnVisible = false;
      this.hide();
    };

    this.el.addEventListener("tymeslot:lv-disconnected", this.onDisconnected);
    this.el.addEventListener("tymeslot:lv-connected", this.onConnected);
    document.addEventListener("visibilitychange", this.onVisibilityChange);
  },

  destroyed() {
    clearTimeout(this.suppressedShowTimer);
    clearTimeout(this.delayedShowTimer);
    clearTimeout(this.hideTimer);
    this.pendingShowOnVisible = false;
    this.el.removeEventListener("tymeslot:lv-disconnected", this.onDisconnected);
    this.el.removeEventListener("tymeslot:lv-connected", this.onConnected);
    document.removeEventListener("visibilitychange", this.onVisibilityChange);
  },

  show() {
    this.el.style.display = "";
    // next frame to allow transition
    requestAnimationFrame(() => {
      this.el.classList.remove("opacity-0", "translate-x-8");
      this.el.classList.add("opacity-100", "translate-x-0");
    });
  },

  hide() {
    this.el.classList.add("opacity-0", "translate-x-8");
    this.el.classList.remove("opacity-100", "translate-x-0");

    clearTimeout(this.hideTimer);
    this.hideTimer = setTimeout(() => {
      // Only fully hide if we are still connected (avoid hiding while disconnected).
      if (!this.isDisconnected) this.el.style.display = "none";
    }, 350);
  }
};

// Auto-scroll to slots on mobile and tablet when slots are loaded
export const AutoScrollToSlots = {
  mounted() {
    this.handleSlotsUpdate = () => {
      // Skip auto-scroll when embedded in an iframe (modal handles its own viewport)
      if (document.documentElement.hasAttribute('data-embedded')) return;

      // Scroll on mobile and tablet viewports (when layout is stacked)
      if (window.innerWidth < 1024) {
        // Check if slots have been loaded (not empty state)
        const hasSlots = this.el.querySelector('[data-slots-loaded]') ||
                        this.el.querySelector('.space-y-3') ||
                        this.el.querySelector('.animate-spin');
        
        if (hasSlots) {
          // Small delay to ensure DOM is fully updated
          setTimeout(() => {
            this.el.scrollIntoView({ 
              behavior: 'smooth', 
              block: 'start',
              inline: 'nearest' 
            });
          }, 100);
        }
      }
    };

    // Observe changes to the slots container
    this.observer = new MutationObserver(this.handleSlotsUpdate);
    this.observer.observe(this.el, { 
      childList: true, 
      subtree: true 
    });
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  }
};

// Auto-focus hook for input fields that need immediate focus
export const AutoFocus = {
  mounted() {
    // Focus the input element immediately
    this.el.focus();

    // Optional: Select all text if the input has a value
    if (this.el.value) {
      this.el.select();
    }
  }
};

// Re-focuses the descendant marked `autofocus` whenever this element's
// `data-state` attribute changes. Plain HTML `autofocus` only fires when a
// node is first inserted into the document; LiveView patches (e.g. switching
// between login/signup within the same view via push_patch) morph the
// existing node in place instead of recreating it, so the browser never
// re-runs its native autofocus handling. `updated()` fires on every patch
// touching this element's subtree, so we gate on `data-state` actually
// changing to avoid stealing focus back on every keystroke's validate round-trip.
export const AuthAutoFocus = {
  mounted() {
    this.lastState = this.el.dataset.state;
    this.focusTarget();
  },
  updated() {
    const state = this.el.dataset.state;
    if (state !== this.lastState) {
      this.lastState = state;
      this.focusTarget();
    }
  },
  focusTarget() {
    this.el.querySelector('[autofocus]')?.focus();
  }
};

// Scroll the whole page back to the top.
//
// The global `html, body { height: 100% }` + `overflow-x: hidden` rules
// (base.css) promote <body> to the scroll container, so `window.scrollTo`
// alone is a no-op on full-page views. Reset every plausible scroll root to
// cover both the window-scroller and body-scroller layouts.
export function scrollPageToTop() {
  window.scrollTo({ top: 0, behavior: 'instant' });
  document.documentElement.scrollTop = 0;
  document.body.scrollTop = 0;
}

// Decide whether a LiveView `phx:navigate` event should reset scroll to the
// top. Only forward `navigate` redirects qualify: `patch` navigations keep
// their scroll position (filters, tabs, multi-step flows), and back/forward
// (`pop`) navigation lets LiveView restore the previously saved position.
export function shouldScrollToTopOnNavigate(detail) {
  return !detail.pop && !detail.patch;
}

// Reset scroll position to top when action changes (on navigation)
export const ScrollReset = {
  mounted() {
    this.currentAction = String(this.el.dataset.action || '');
    this.scrollToTop();
  },

  updated() {
    const newAction = String(this.el.dataset.action || '');
    const currentActionStr = String(this.currentAction || '');

    if (newAction !== currentActionStr) {
      this.currentAction = newAction;
      this.scrollToTop();
    }
  },

  scrollToTop() {
    // Check if we should scroll the window (for full-page views) or the element
    const scrollWindow = this.el.dataset.scrollWindow === 'true' ||
                        this.el.scrollHeight <= this.el.clientHeight;

    if (scrollWindow) {
      scrollPageToTop();
    } else {
      // If the element has a scroll height, reset its scroll
      this.el.scrollTop = 0;
    }
  }
};

// Copy text to clipboard and show feedback
export const CopyOnClick = {
  mounted() {
    this.el.addEventListener("click", () => {
      const text = this.el.dataset.copyText;
      if (!text) return;

      if (navigator.clipboard) {
        navigator.clipboard.writeText(text).then(() => {
          this.showFeedback();
        }).catch(err => {
          console.error("Failed to copy:", err);
          this.showFeedback("Failed to copy to clipboard");
        });
      } else {
        // Fallback or error notification
        this.showFeedback("Clipboard access unavailable");
      }
    });
  },

  showFeedback(message) {
    // Dispatch a custom event that can be listened to for showing notifications
    // This allows for zero-roundtrip feedback
    const event = new CustomEvent("tymeslot:clip-copy", {
      detail: { message: message || this.el.dataset.copyFeedback || "Copied to clipboard!" }
    });
    window.dispatchEvent(event);

    // If there's a specific feedback element, show it
    const feedbackId = this.el.dataset.feedbackId;
    if (feedbackId) {
      const feedbackEl = document.getElementById(feedbackId);
      if (feedbackEl) {
        feedbackEl.classList.remove("hidden");
        setTimeout(() => feedbackEl.classList.add("hidden"), 2000);
      }
    }
  }
};
