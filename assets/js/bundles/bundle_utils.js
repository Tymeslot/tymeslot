/**
 * Bundle Initialization Utilities
 *
 * Shared utilities for route-specific bundles to initialize and connect
 * to the LiveSocket instance created by the core bundle.
 */

const MAX_RETRIES = 100; // 10 seconds max (100 * 100ms)
const RETRY_INTERVAL = 100; // ms between retries

/**
 * Initialize a route-specific bundle by extending CoreHooks and connecting LiveSocket
 *
 * @param {string} bundleName - Name of the bundle for logging (e.g., "dashboard", "auth")
 * @param {Object} additionalHooks - Hook definitions specific to this route
 * @returns {Promise<void>} Resolves when initialized, rejects on timeout or error
 */
export function initializeBundle(bundleName, additionalHooks = {}) {
  return new Promise((resolve, reject) => {
    let retries = 0;

    const attemptInitialization = () => {
      // Check if core bundle has loaded
      if (window.liveSocket && window.CoreHooks) {
        try {
          // Extend CoreHooks with route-specific hooks
          const bundleHooks = { ...window.CoreHooks, ...additionalHooks };

          // Update LiveSocket hooks before connection
          window.liveSocket.hooks = bundleHooks;

          // Connect if not already connected
          if (!window.liveSocket.isConnected()) {
            window.liveSocket.connect();
          }

          // Emit success telemetry
          window.dispatchEvent(new CustomEvent('tymeslot:bundle:loaded', {
            detail: { bundle: bundleName, success: true, retries }
          }));

          resolve();
        } catch (error) {
          console.error(`Failed to initialize ${bundleName} bundle:`, error);

          // Emit failure telemetry
          window.dispatchEvent(new CustomEvent('tymeslot:bundle:loaded', {
            detail: { bundle: bundleName, success: false, error: error.message, retries }
          }));

          reject(error);
        }
      } else {
        // Core bundle not ready yet
        retries++;

        if (retries >= MAX_RETRIES) {
          const error = new Error(
            `Timeout waiting for core bundle after ${(MAX_RETRIES * RETRY_INTERVAL) / 1000} seconds`
          );

          console.error(`Failed to initialize ${bundleName} bundle:`, error);

          // Emit timeout telemetry
          window.dispatchEvent(new CustomEvent('tymeslot:bundle:loaded', {
            detail: { bundle: bundleName, success: false, error: error.message, retries }
          }));

          // Show user-friendly error
          showBundleError(bundleName, 'Core bundle failed to load. Please refresh the page.');

          reject(error);
        } else {
          // Retry after interval
          setTimeout(attemptInitialization, RETRY_INTERVAL);
        }
      }
    };

    // Start initialization
    attemptInitialization();
  });
}

/**
 * Show a user-visible error message when bundle loading fails
 *
 * @param {string} bundleName - Name of the bundle that failed
 * @param {string} message - User-friendly error message
 */
function showBundleError(bundleName, message) {
  // Try to use existing flash container
  const container = document.getElementById('flash-group') || document.body;

  const errorDiv = document.createElement('div');
  errorDiv.className = 'fixed top-4 right-4 z-[10060] w-80 sm:w-96 rounded-2xl p-5 shadow-2xl border-2 bg-red-50 border-red-100 text-red-900 shadow-red-500/10';
  errorDiv.setAttribute('role', 'alert');

  errorDiv.innerHTML = `
    <div class="relative z-10 flex items-start gap-4">
      <div class="shrink-0 w-10 h-10 rounded-xl flex items-center justify-center shadow-sm border bg-white border-red-100 text-red-500">
        <svg class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z" />
        </svg>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-bold leading-relaxed">${message}</p>
        <button class="mt-2 text-sm underline hover:no-underline" data-bundle-reload>
          Refresh Page
        </button>
      </div>
    </div>
  `;

  // Inline `onclick` handlers are blocked by the CSP (no 'unsafe-inline'), so
  // wire the reload up via a real listener after the markup is inserted.
  errorDiv
    .querySelector('[data-bundle-reload]')
    ?.addEventListener('click', () => location.reload());

  container.appendChild(errorDiv);
}
