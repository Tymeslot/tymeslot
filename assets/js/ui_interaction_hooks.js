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