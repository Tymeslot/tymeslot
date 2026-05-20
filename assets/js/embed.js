/**
 * Tymeslot Booking Widget
 * 
 * Provides multiple embedding modes for Tymeslot booking pages:
 * - Inline: Embeds directly into a div
 * - Popup: Opens in a modal overlay
 * - Floating: Fixed button that opens popup
 * 
 * Usage:
 * 1. Inline: <div id="tymeslot-booking" data-username="sarah"></div>
 * 2. Popup: <button onclick="TymeslotBooking.open('sarah')">Book</button>
 * 3. Floating: TymeslotBooking.initFloating('sarah')
 */

(function() {
  'use strict';

  /**
   * Global Error Handling
   */
  const failSafe = (msg) => {
    console.error('Tymeslot Error:', msg);
    const containers = document.querySelectorAll('#tymeslot-booking, [data-tymeslot-inline]');
    containers.forEach(c => {
      if (typeof TymeslotBooking !== 'undefined' && TymeslotBooking.showError) {
        TymeslotBooking.showError(c);
      } else {
        const errorDiv = document.createElement('div');
        errorDiv.style.cssText = 'padding:20px;color:#991b1b;background:#fef2f2;border:1px solid #fecaca;border-radius:8px;font-family:sans-serif;';
        const strong = document.createElement('strong');
        strong.textContent = 'Booking system unavailable.';
        errorDiv.appendChild(strong);
        c.replaceChildren(errorDiv);
      }
    });
  };

  window.addEventListener('error', function(e) {
    if (e.filename && /\/embed[^/]*\.js/.test(e.filename)) {
      failSafe(e.message);
    }
  });

  // Configuration
  const CONFIG = {
    // Get base URL from script tag or current domain
    getBaseUrl: function() {
      // 1. Try modern currentScript API
      if (document.currentScript) {
        return new URL(document.currentScript.src).origin;
      }
      // 2. Fallback to searching script tags
      const script = document.querySelector('script[src*="embed.js"]');
      if (script) {
        const src = script.getAttribute('src');
        const url = new URL(src, window.location.href);
        return url.origin;
      }
      return window.location.origin;
    }
  };

  const BASE_URL = CONFIG.getBaseUrl();

  function modalContentMaxHeight() {
    // 50px headroom top/bottom — matches cal.com's getMaxHeightForModal()
    // and gives the close button breathing room above the iframe content.
    return Math.max(window.innerHeight - 100, 200);
  }

  /**
   * Global message listener for iframe resizing.
   *
   * The embedded page posts {type: 'tymeslot-resize', height, isFirstTime}
   * on a 50ms loop (see iframe_embed.js). We apply the posted height to
   * the iframe's wrapper verbatim so the iframe grows AND shrinks with
   * content — that's what eliminates dead space at the bottom when the
   * booking page transitions between long and short steps.
   *
   * If the wrapper is constrained (modal, or an inline container with an
   * explicit max-height set by the embedder), the posted height is
   * capped at the constraint and the browser scrolls inside the iframe.
   */
  window.addEventListener('message', function(e) {
    if (e.origin !== BASE_URL) return;
    if (!e.data || typeof e.data !== 'object') return;
    if (e.data.type !== 'tymeslot-resize') return;

    var h = Number(e.data.height);
    if (!Number.isFinite(h) || h <= 0) return;

    var iframes = document.querySelectorAll('iframe[title="Booking Widget"]');
    iframes.forEach(function(iframe) {
      if (iframe.contentWindow !== e.source) return;
      var wrapper = iframe.parentNode;
      if (!wrapper) return;

      if (wrapper.dataset.constrained) {
        var cap = parseInt(wrapper.dataset.constraintHeight, 10);
        if (!cap || cap <= 0) return;
        wrapper.style.height = Math.min(h, cap) + 'px';
      } else {
        // Unconstrained inline embed — match content height exactly.
        wrapper.style.height = h + 'px';
        wrapper.style.minHeight = '0';
      }
    });
  });

  /**
   * Create an iframe for embedding
   */
  function createBookingIframe(username, options = {}) {
    const iframe = document.createElement('iframe');
    const base = BASE_URL.replace(/\/$/, '');
    const url = new URL(`${base}/${encodeURIComponent(username)}`);
    
    // Build URL with customization params - STRICT ALLOWLIST
    const ALLOWED_PARAMS = ['theme', 'primaryColor', 'locale', 'layout'];

    ALLOWED_PARAMS.forEach(key => {
      const val = options[key];
      if (!val) return;

      if (key === 'theme' && /^\d+$/.test(val)) {
        url.searchParams.append('theme', val);
      } else if (key === 'primaryColor' && /^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$/.test(val)) {
        url.searchParams.append('primary-color', val);
      } else if (key === 'locale' && /^[a-z]{2}(-[a-zA-Z0-9]+)?$/.test(val)) {
        url.searchParams.append('locale', val);
      } else if (key === 'layout' && /^(default|column)$/.test(val)) {
        url.searchParams.append('layout', val);
      }
    });

    // Signal embedded context to the server for token generation
    url.searchParams.append('embed', '1');

    // Inline embeds use a fixed viewport — the embedded page fills the iframe
    // exactly (height: 100%, overflow: hidden) so content adapts to the
    // available space rather than causing iframe-level scrolling.
    // Modal embeds omit this so the page can report its content height.
    if (options._mode !== 'modal') {
      url.searchParams.append('embed-mode', 'inline');
    }

    // Pass parent origin so iframe_embed.js can post resize messages
    // even when the embedding page strips the Referrer header.
    url.searchParams.append('parent-origin', window.location.origin);

    iframe.src = url.toString();
    iframe.style.cssText = `
      width: 100%;
      height: 100%;
      border: none;
      background: transparent;
      transition: opacity 0.3s ease;
      opacity: 0;
    `;
    iframe.setAttribute('scrolling', 'auto');
    iframe.setAttribute('title', 'Booking Widget');

    // Create wrapper. The wrapper starts at `initialHeight` as a
    // placeholder shown before iframe_embed.js posts its first
    // measurement; thereafter the resize handler grows/shrinks the
    // wrapper to match content. `data-min-height` is still accepted
    // as a legacy alias for `data-initial-height`.
    const rawInitial = options.initialHeight || options.minHeight;
    const initialHeight = Math.min(Math.max(parseInt(rawInitial, 10) || 400, 200), 2000);
    const maxWidth = Math.min(Math.max(parseInt(options.maxWidth, 10) || 1000, 200), 2000);
    const wrapper = document.createElement('div');
    wrapper.style.position = 'relative';
    wrapper.style.width = '100%';
    wrapper.style.maxWidth = maxWidth + 'px';
    wrapper.style.marginLeft = 'auto';
    wrapper.style.marginRight = 'auto';
    wrapper.style.height = initialHeight + 'px';

    const loader = document.createElement('div');
    loader.className = 'tymeslot-loader';
    loader.style.cssText = `
      position: absolute;
      top: 50%;
      left: 50%;
      transform: translate(-50%, -50%);
      display: flex;
      flex-direction: column;
      align-items: center;
      font-family: sans-serif;
      color: #64748b;
    `;
    
    const spinner = document.createElement('div');
    spinner.style.cssText = 'width: 40px; height: 40px; border: 3px solid #f3f3f3; border-top: 3px solid #14B8A6; border-radius: 50%; animation: tymeslot-spin 1s linear infinite;';
    
    const loadingText = document.createElement('span');
    loadingText.style.cssText = 'margin-top: 12px; font-size: 14px;';
    loadingText.textContent = 'Loading booking page...';
    
    const style = document.createElement('style');
    style.textContent = '@keyframes tymeslot-spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }';
    
    loader.appendChild(spinner);
    loader.appendChild(loadingText);
    loader.appendChild(style);
    wrapper.appendChild(loader);

    // Add loading timeout
    let retryCount = 0;
    const maxRetries = 2;
    const TIMEOUT_MS = 15000;

    const handleTimeout = () => {
      if (wrapper.parentNode && !iframe.dataset.loaded) {
        if (retryCount < maxRetries) {
          retryCount++;
          const currentUrl = new URL(iframe.src);
          currentUrl.searchParams.set('_retry', retryCount);
          iframe.src = currentUrl.toString();
          // Reassign so iframe.onload can cancel this retry's timeout too
          timeout = setTimeout(handleTimeout, TIMEOUT_MS);
        } else {
          showError(wrapper, loader);
          if (iframe.parentNode) iframe.remove();
        }
      }
    };

    let timeout = setTimeout(handleTimeout, TIMEOUT_MS);

    iframe.onload = () => {
      iframe.dataset.loaded = 'true';
      iframe.style.opacity = '1';
      if (loader.parentNode) loader.remove();
      clearTimeout(timeout);
    };
    
    wrapper.appendChild(iframe);
    return wrapper;
  }

  /**
   * Show error message in container
   */
  function showError(container, elementToReplace) {
    const error = document.createElement('div');
    error.style.cssText = 'padding: 24px; color: #991b1b; background: #fef2f2; border: 2px solid #fecaca; border-radius: 12px; text-align: center; font-family: sans-serif;';
    
    const title = document.createElement('strong');
    title.textContent = 'Booking widget is taking too long to load.';
    
    const subtext = document.createElement('p');
    subtext.style.cssText = 'margin-top: 8px; font-size: 14px; color: #b91c1c;';
    subtext.textContent = 'Please check your connection or refresh the page.';
    
    error.appendChild(title);
    error.appendChild(document.createElement('br'));
    error.appendChild(subtext);
    
    if (elementToReplace && elementToReplace.parentNode === container) {
      container.replaceChild(error, elementToReplace);
    } else {
      container.innerHTML = '';
      container.appendChild(error);
    }
  }

  /**
   * Inject the one-time stylesheet that gives the modal an edge-to-edge
   * full-screen layout below 768px. Inline modal styles can't carry
   * media queries, so we use a small stylesheet keyed on the modal's id.
   */
  function ensureModalStyles() {
    if (document.getElementById('tymeslot-modal-styles')) return;
    const styleEl = document.createElement('style');
    styleEl.id = 'tymeslot-modal-styles';
    styleEl.textContent = '@media (max-width: 768px) {' +
      '#tymeslot-modal { padding: 0 !important; }' +
      '#tymeslot-modal [data-tymeslot-container] {' +
        'max-width: 100% !important;' +
        'max-height: 100% !important;' +
        'height: 100% !important;' +
        'width: 100% !important;' +
        'border-radius: 0 !important;' +
      '}' +
    '}';
    document.head.appendChild(styleEl);
  }

  /**
   * Create modal overlay
   *
   * Default content width is 1000px — wide enough to comfortably show
   * theme hero sections (Rhythm's video background, etc.) instead of
   * cramming them into a narrow column. On viewports <= 768px the
   * media-query stylesheet collapses the modal to full-screen.
   */
  function createModal(contentMaxWidth = 1000) {
    ensureModalStyles();

    const modal = document.createElement('div');
    modal.id = 'tymeslot-modal';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.setAttribute('aria-label', 'Booking Widget');
    modal.style.cssText = `
      position: fixed;
      top: 0;
      left: 0;
      width: 100%;
      height: 100%;
      background: rgba(0, 0, 0, 0.75);
      z-index: 999999;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
      opacity: 0;
      transition: opacity 0.3s ease;
    `;

    const container = document.createElement('div');
    container.setAttribute('data-tymeslot-container', '');
    container.style.cssText = `
      position: relative;
      width: 100%;
      max-width: min(${contentMaxWidth}px, calc(100vw - 32px));
      max-height: calc(100vh - 100px);
      background: transparent;
      border-radius: 16px;
      overflow: hidden;
      box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
      transform: scale(0.95);
      transition: transform 0.3s ease;
    `;
    
    const closeButton = document.createElement('button');
    closeButton.textContent = '\u00D7';
    closeButton.style.cssText = `
      position: absolute;
      top: 16px;
      right: 16px;
      width: 40px;
      height: 40px;
      border: none;
      background: rgba(0, 0, 0, 0.5);
      color: white;
      font-size: 32px;
      line-height: 1;
      border-radius: 50%;
      cursor: pointer;
      z-index: 10;
      transition: all 0.2s ease;
      display: flex;
      align-items: center;
      justify-content: center;
    `;
    closeButton.setAttribute('aria-label', 'Close booking widget');

    closeButton.onmouseover = function() {
      this.style.background = 'rgba(0, 0, 0, 0.7)';
      this.style.transform = 'scale(1.1)';
    };
    closeButton.onmouseout = function() {
      this.style.background = 'rgba(0, 0, 0, 0.5)';
      this.style.transform = 'scale(1)';
    };
    
    closeButton.onclick = function() {
      TymeslotBooking.close();
    };
    
    modal.onclick = function(e) {
      if (e.target === modal) {
        TymeslotBooking.close();
      }
    };
    
    container.appendChild(closeButton);
    modal.appendChild(container);

    // Animate in
    setTimeout(() => {
      modal.style.opacity = '1';
      container.style.transform = 'scale(1)';
    }, 10);

    return { modal, container, closeButton };
  }

  /**
   * Create floating button
   */
  function createFloatingButton(username, options = {}) {
    const button = document.createElement('button');
    button.id = 'tymeslot-floating-button';
    button.setAttribute('aria-label', 'Book a meeting');
    button.setAttribute('title', 'Book a meeting');

    const buttonColor = /^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$/.test(options.buttonColor)
      ? options.buttonColor
      : '#14B8A6'; // turquoise-600

    button.style.cssText = `
      position: fixed;
      bottom: 24px;
      right: 24px;
      width: 64px;
      height: 64px;
      border-radius: 50%;
      background: ${buttonColor};
      color: white;
      border: none;
      cursor: pointer;
      box-shadow: 0 10px 25px rgba(0, 0, 0, 0.3);
      z-index: 999998;
      transition: all 0.3s ease;
      display: flex;
      align-items: center;
      justify-content: center;
    `;
    
    button.innerHTML = `
      <svg width="32" height="32" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"></path>
      </svg>
    `;
    
    button.onmouseover = function() {
      this.style.transform = 'scale(1.1)';
      this.style.boxShadow = '0 15px 35px rgba(0, 0, 0, 0.4)';
    };
    
    button.onmouseout = function() {
      this.style.transform = 'scale(1)';
      this.style.boxShadow = '0 10px 25px rgba(0, 0, 0, 0.3)';
    };
    
    button.onclick = function() {
      TymeslotBooking.open(username, options);
    };
    
    return button;
  }

  /**
   * Initialize inline embeds on page load
   */
  function initInlineEmbeds() {
    const containers = document.querySelectorAll('#tymeslot-booking, [data-tymeslot-inline]');
    
    containers.forEach(container => {
      const username = container.getAttribute('data-username') || 
                      container.getAttribute('data-tymeslot-inline');
      
      if (!validateUsername('initInlineEmbeds', username)) return;
      
      const options = {
        theme: container.getAttribute('data-theme'),
        primaryColor: container.getAttribute('data-primary-color'),
        locale: container.getAttribute('data-locale'),
        layout: container.getAttribute('data-layout'),
        initialHeight:
          container.getAttribute('data-initial-height') ||
          container.getAttribute('data-min-height'),
        maxWidth: container.getAttribute('data-max-width')
      };
      
      const wrapper = createBookingIframe(username, options);
      container.innerHTML = '';
      container.appendChild(wrapper);
      ensureScrollable(container, wrapper);
    });
  }

  /**
   * When the container has a constrained height, make the wrapper and
   * iframe fill it exactly. The iframe's scrolling="auto" attribute
   * provides a scrollbar for the booking page content inside.
   *
   * Constraint detection: checks for an explicit max-height or an inline
   * height style on the container element. Computed height is intentionally
   * not used — getComputedStyle always returns a pixel value, so checking it
   * would incorrectly flag any unconstrained element sized by its content.
   */
  function ensureScrollable(container, wrapper) {
    var style = window.getComputedStyle(container);
    var maxHeight = style.maxHeight;
    var hasMaxHeight = maxHeight !== 'none' && maxHeight !== '' && parseInt(maxHeight, 10) > 0;
    var hasInlineHeight = container.style.height !== '' && container.style.height !== 'auto';

    if (hasMaxHeight || hasInlineHeight) {
      requestAnimationFrame(function() {
        var actualHeight = container.clientHeight;
        if (wrapper) {
          wrapper.style.height = actualHeight + 'px';
          wrapper.style.minHeight = '0';
          wrapper.dataset.constrained = 'true';
          wrapper.dataset.constraintHeight = String(actualHeight);
        }
      });
    }
  }

  function validateUsername(methodName, username) {
    if (!username) {
      console.error('Tymeslot: No username provided to ' + methodName + '()');
      return false;
    }
    return true;
  }

  /**
   * Public API
   */
  window.TymeslotBooking = {
    /**
     * Display error in a container
     */
    showError: function(selectorOrElement) {
      let container = selectorOrElement;
      if (typeof selectorOrElement === 'string') {
        container = document.querySelector(selectorOrElement);
      }
      if (container) {
        showError(container);
      }
    },

    /**
     * Open booking in a modal
     */
    open: function(username, options = {}) {
      // Remove existing modal if any
      this.close();
      if (!validateUsername('open', username)) return;

      // If the page has an inline container with data-max-width, treat it as
      // the default for the popup too — so embedders who configure a single
      // div get matching popup sizing without repeating the value in JS.
      if (!options.maxWidth) {
        const inlineDiv = document.querySelector(
          '#tymeslot-booking[data-max-width], [data-tymeslot-inline][data-max-width]'
        );
        if (inlineDiv) {
          options = Object.assign({}, options, {
            maxWidth: inlineDiv.getAttribute('data-max-width')
          });
        }
      }

      const contentMaxWidth = Math.min(Math.max(parseInt(options.maxWidth, 10) || 1000, 200), 2000);
      const { modal, container, closeButton } = createModal(contentMaxWidth);
      const wrapper = createBookingIframe(username, Object.assign({}, options, { _mode: 'modal' }));
      const iframe = wrapper.querySelector('iframe');

      if (iframe) {
        iframe.style.width = '100%';
        iframe.style.height = '100%';
        iframe.style.minHeight = '0';

        // Cap at viewport height so the iframe scrolls if content exceeds it.
        // Don't pre-set the wrapper height — let it shrink-wrap to actual
        // content once the iframe reports its size via postMessage.
        var maxH = modalContentMaxHeight();
        wrapper.style.minHeight = '0';
        wrapper.dataset.constrained = 'true';
        wrapper.dataset.constraintHeight = String(maxH);

        container.appendChild(wrapper);
      }

      modal._previousFocus = document.activeElement;
      document.body.appendChild(modal);
      modal.previousBodyOverflow = document.body.style.overflow;
      document.body.style.overflow = 'hidden';
      // Move focus into the dialog for keyboard/screen reader users
      closeButton.focus();

      // Update constraint on window resize / orientation change
      let resizeRafPending = false;
      const resizeHandler = () => {
        if (!resizeRafPending) {
          resizeRafPending = true;
          requestAnimationFrame(() => {
            resizeRafPending = false;
            var newMax = modalContentMaxHeight();
            if (wrapper.dataset.constrained) {
              wrapper.dataset.constraintHeight = String(newMax);
            }
          });
        }
      };
      window.addEventListener('resize', resizeHandler);
      modal.resizeHandler = resizeHandler;
      
      // Handle keyboard interactions: Escape closes, Tab cycles within modal
      const FOCUSABLE = 'a[href], button:not([disabled]), textarea, input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"]), iframe';
      const escapeHandler = (e) => {
        if (e.key === 'Escape') {
          this.close();
          return;
        }
        if (e.key === 'Tab') {
          const focusable = Array.from(modal.querySelectorAll(FOCUSABLE)).filter(el => !el.hidden && el.getAttribute('aria-hidden') !== 'true');
          if (focusable.length === 0) return;
          const first = focusable[0];
          const last = focusable[focusable.length - 1];
          if (e.shiftKey && document.activeElement === first) {
            e.preventDefault();
            last.focus();
          } else if (!e.shiftKey && document.activeElement === last) {
            e.preventDefault();
            first.focus();
          }
        }
      };
      document.addEventListener('keydown', escapeHandler);
      modal.escapeHandler = escapeHandler;
    },
    
    /**
     * Close the modal
     */
    close: function() {
      const modal = document.getElementById('tymeslot-modal');
      if (modal) {
        const container = modal.querySelector('[data-tymeslot-container]');
        modal.style.opacity = '0';
        if (container) {
          container.style.transform = 'scale(0.95)';
        }
        
        setTimeout(() => {
          if (modal.escapeHandler) {
            document.removeEventListener('keydown', modal.escapeHandler);
          }
          if (modal.resizeHandler) {
            window.removeEventListener('resize', modal.resizeHandler);
          }
          const prevFocus = modal._previousFocus;
          modal.remove();
          document.body.style.overflow = modal.previousBodyOverflow || '';
          // Restore focus to the element that was active before the modal opened
          if (prevFocus && typeof prevFocus.focus === 'function') {
            prevFocus.focus();
          }
        }, 300);
      }
    },
    
    /**
     * Initialize floating button
     */
    initFloating: function(username, options = {}) {
      if (!validateUsername('initFloating', username)) return;

      // Remove existing button if any
      const existing = document.getElementById('tymeslot-floating-button');
      if (existing) existing.remove();

      const button = createFloatingButton(username, options);
      document.body.appendChild(button);
    },

    /**
     * Programmatically embed inline
     */
    embed: function(selector, username, options = {}) {
      if (!validateUsername('embed', username)) return;

      const container = document.querySelector(selector);
      if (!container) {
        console.error('Tymeslot: Container not found:', selector);
        return;
      }

      // Inherit initial-height and max-width from container data attributes
      // if not already passed in options. `data-min-height` is still accepted
      // as a legacy alias for `data-initial-height`.
      if (!options.initialHeight) {
        const attr =
          container.getAttribute('data-initial-height') ||
          container.getAttribute('data-min-height');
        if (attr) options.initialHeight = attr;
      }
      if (!options.maxWidth && container.getAttribute('data-max-width')) {
        options.maxWidth = container.getAttribute('data-max-width');
      }

      const wrapper = createBookingIframe(username, options);
      container.innerHTML = '';
      container.appendChild(wrapper);
      ensureScrollable(container, wrapper);
    }
  };

  /**
   * Initialize when DOM is ready
   */
  const init = () => {
    try {
      initInlineEmbeds();
    } catch (e) {
      failSafe(e.message);
    }
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
