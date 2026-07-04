// UI interaction hooks for LiveView
// Handles user interactions like confirmations, external links, and page reloads

// Confirmation dialog hook
export const ConfirmDelete = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      const message = this.el.dataset.confirm || 'Are you sure?';
      if (!confirm(message)) {
        e.preventDefault();
        e.stopPropagation();
      }
    });
  }
};


// Page reload hook
export const PageReload = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      e.preventDefault();
      window.location.reload();
    });
  }
};


// Play a preset's preview <video> while the pointer hovers its container.
// Replaces inline onmouseenter/onmouseleave handlers (blocked by a nonce-based CSP).
export const VideoHoverPreview = {
  mounted() {
    const video = this.el.querySelector('.video-preview');
    if (!video) return;
    this.onEnter = () => {
      video.currentTime = 0;
      video.play().catch(() => {});
    };
    this.onLeave = () => video.pause();
    this.el.addEventListener('mouseenter', this.onEnter);
    this.el.addEventListener('mouseleave', this.onLeave);
  },
  destroyed() {
    this.el.removeEventListener('mouseenter', this.onEnter);
    this.el.removeEventListener('mouseleave', this.onLeave);
  }
};


// Stop click events from bubbling past this element (e.g. an all-day event chip
// nested in a clickable day cell). Replaces inline onclick="event.stopPropagation()".
export const StopClickPropagation = {
  mounted() {
    this.onClick = (e) => e.stopPropagation();
    this.el.addEventListener('click', this.onClick);
  },
  destroyed() {
    this.el.removeEventListener('click', this.onClick);
  }
};


// Accessibility for the core <.modal>. The overlay is a display:none/flex
// toggled <div> (driven either by a server assign or a client-side JS.hide/
// JS.show command), so we watch the `style` attribute rather than relying on
// mount/unmount. When the modal becomes visible we remember the element that
// had focus, move focus into the dialog, and trap Tab within it; when it hides
// again we restore focus to wherever it came from. This gives every modal in
// the app keyboard containment and focus restoration in one place.
const FOCUSABLE_SELECTOR = [
  'a[href]',
  'button:not([disabled])',
  'input:not([disabled])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  '[tabindex]:not([tabindex="-1"])',
  'iframe',
  'audio[controls]',
  'video[controls]',
  '[contenteditable]:not([contenteditable="false"])'
].join(',');

export const ModalFocusTrap = {
  mounted() {
    this.active = false;
    this.previouslyFocused = null;
    this.onKeydown = (e) => this.handleKeydown(e);
    this.observer = new MutationObserver(() => this.syncVisibility());
    this.observer.observe(this.el, { attributes: true, attributeFilter: ['style'] });
    this.syncVisibility();
  },

  updated() {
    this.syncVisibility();
  },

  destroyed() {
    this.observer?.disconnect();
    this.release();
  },

  isVisible() {
    // The component toggles the overlay purely via inline `display`, and the
    // observer only watches this element's `style`, so that is the canonical
    // visibility signal.
    return this.el.style.display !== 'none';
  },

  syncVisibility() {
    if (this.isVisible()) {
      this.activate();
    } else {
      this.release();
    }
  },

  focusable() {
    // getClientRects().length also catches position:fixed elements, which
    // offsetParent === null incorrectly treats as hidden.
    //
    // Note: an <iframe> can be included in this list and act as the first/
    // last stop for Tab, but a keydown fired inside a cross-document iframe
    // cannot be intercepted by this listener — full containment of the
    // iframe's own document content is not achievable from the parent frame.
    return Array.from(this.el.querySelectorAll(FOCUSABLE_SELECTOR))
      .filter((el) => el.getClientRects().length > 0);
  },

  activate() {
    if (this.active) return;
    this.active = true;
    this.previouslyFocused =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;

    const items = this.focusable();
    const target = items[0] || this.el.querySelector('[role="dialog"]') || this.el;
    // Defer so the browser has painted the now-visible modal before we focus.
    requestAnimationFrame(() => target?.focus());

    document.addEventListener('keydown', this.onKeydown, true);
  },

  release() {
    if (!this.active) return;
    this.active = false;
    document.removeEventListener('keydown', this.onKeydown, true);

    const restore = this.previouslyFocused;
    this.previouslyFocused = null;
    if (restore && typeof restore.focus === 'function') restore.focus();
  },

  handleKeydown(e) {
    if (e.key !== 'Tab' || !this.active) return;

    const items = this.focusable();
    if (items.length === 0) {
      e.preventDefault();
      return;
    }

    const first = items[0];
    const last = items[items.length - 1];

    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  }
};