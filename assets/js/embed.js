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
        c.innerHTML = '<div style="padding:20px;color:#991b1b;background:#fef2f2;border:1px solid #fecaca;border-radius:8px;font-family:sans-serif;"><strong>Booking system unavailable.</strong></div>';
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

  function viewportMaxHeight() {
    return Math.floor(Math.min(window.innerHeight * 0.9, window.innerHeight - 40));
  }

  /**
   * Global message listener for iframe resizing.
   *
   * When the embedded page reports its content height, resize the iframe
   * to fit — but only up to the container's own constraints. If the
   * container has a max-height, the iframe stays within it and the
   * embedded page scrolls internally (handled by iframe_embed.js CSS).
   */
  window.addEventListener('message', function(e) {
    if (e.origin !== BASE_URL) return;
    if (!e.data || typeof e.data !== 'object') return;
    if (e.data.type === 'tymeslot-resize') {
      var h = Number(e.data.height);
      if (!Number.isFinite(h) || h <= 0) return;

      var iframes = document.querySelectorAll('iframe[title="Booking Widget"]');
      iframes.forEach(function(iframe) {
        if (iframe.contentWindow === e.source) {
          var wrapper = iframe.parentNode;
          if (!wrapper) return;

          if (wrapper.dataset.constrained) {
            // Constrained: shrink to content but never exceed the constraint
            var cap = parseInt(wrapper.dataset.constraintHeight, 10);
            if (!cap || cap <= 0) return;
            wrapper.style.height = Math.min(h, cap) + 'px';
          } else {
            var floor = parseInt(wrapper.dataset.minHeight || '0', 10);
            if (floor > 0) {
              wrapper.style.height = Math.max(h, floor) + 'px';
              wrapper.style.minHeight = floor + 'px';
            } else {
              wrapper.style.height = h + 'px';
              wrapper.style.minHeight = '0';
            }
          }
        }
      });
    }
  });

  /**
   * Create an iframe for embedding
   */
  function createBookingIframe(username, options = {}) {
    const iframe = document.createElement('iframe');
    const base = BASE_URL.replace(/\/$/, '');
    const url = new URL(`${base}/${encodeURIComponent(username)}`);
    
    // Build URL with customization params - STRICT ALLOWLIST
    const ALLOWED_PARAMS = ['theme', 'primaryColor', 'locale'];

    ALLOWED_PARAMS.forEach(key => {
      const val = options[key];
      if (!val) return;

      if (key === 'theme' && /^\d+$/.test(val)) {
        url.searchParams.append('theme', val);
      } else if (key === 'primaryColor' && /^#([A-Fa-f0-9]{6}|[A-Fa-f0-9]{3})$/.test(val)) {
        url.searchParams.append('primary-color', val);
      } else if (key === 'locale' && /^[a-z]{2}(-[a-zA-Z0-9]+)?$/.test(val)) {
        url.searchParams.append('locale', val);
      }
    });

    // Signal embedded context to the server for token generation
    url.searchParams.append('embed', '1');

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
    iframe.setAttribute('allow', 'payment');
    iframe.setAttribute('title', 'Booking Widget');

    // Create wrapper for loading state.
    // Uses min-height as default for unconstrained containers;
    // constrained containers clip the wrapper and the iframe scrolls internally.
    const minHeight = Math.max(parseInt(options.minHeight, 10) || 320, 200);
    const wrapper = document.createElement('div');
    wrapper.style.position = 'relative';
    wrapper.style.width = '100%';
    wrapper.style.height = minHeight + 'px';
    wrapper.style.minHeight = minHeight + 'px';
    wrapper.dataset.minHeight = String(minHeight);

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
   * Create modal overlay
   */
  function createModal() {
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
    var maxH = viewportMaxHeight();
    container.style.cssText = `
      position: relative;
      width: 100%;
      max-width: min(1000px, calc(100vw - 32px));
      max-height: ${maxH}px;
      background: transparent;
      border-radius: 16px;
      overflow: hidden;
      box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
      transform: scale(0.95);
      transition: transform 0.3s ease;
    `;
    
    const closeButton = document.createElement('button');
    closeButton.innerHTML = '×';
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
        minHeight: container.getAttribute('data-min-height')
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
          var floor = parseInt(wrapper.dataset.minHeight || '0', 10);
          wrapper.style.height = actualHeight + 'px';
          wrapper.style.minHeight = floor > 0 ? floor + 'px' : '0';
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

      const { modal, container, closeButton } = createModal();
      const wrapper = createBookingIframe(username, options);
      const iframe = wrapper.querySelector('iframe');

      if (iframe) {
        iframe.style.width = '100%';
        iframe.style.height = '100%';
        iframe.style.minHeight = '0';

        // Cap at viewport height so the iframe scrolls if content exceeds it.
        // Don't pre-set the wrapper height — let it shrink-wrap to actual
        // content once the iframe reports its size via postMessage.
        var maxH = viewportMaxHeight();
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
      const resizeHandler = () => {
        var newMax = viewportMaxHeight();
        container.style.maxHeight = newMax + 'px';
        if (wrapper.dataset.constrained) {
          wrapper.dataset.constraintHeight = String(newMax);
        }
      };
      window.addEventListener('resize', resizeHandler);
      modal.resizeHandler = resizeHandler;
      
      // Handle escape key
      const escapeHandler = (e) => {
        if (e.key === 'Escape') {
          this.close();
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

      // Inherit min-height from container data attribute if not set in options
      if (!options.minHeight && container.getAttribute('data-min-height')) {
        options.minHeight = container.getAttribute('data-min-height');
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
