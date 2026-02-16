/**
 * Dynamic Hook Loader
 *
 * Enables lazy-loading of LiveView hooks to reduce initial bundle size.
 * Hooks are only loaded when they're actually needed on the page.
 */

// Cache for loaded hooks
const loadedHooks = new Map();
const loadingPromises = new Map();

/**
 * Load a hook module dynamically
 * @param {string} name - Hook name for debugging/caching
 * @param {Function} loader - () => import('./path/to/hook')
 * @returns {Promise<Object>} The loaded hook object
 */
export async function loadHook(name, loader) {
  // Return cached hook if already loaded
  if (loadedHooks.has(name)) {
    return loadedHooks.get(name);
  }

  // Wait for in-progress load
  if (loadingPromises.has(name)) {
    return await loadingPromises.get(name);
  }

  // Start loading
  const loadPromise = loader().then(module => {
    // Use nullish coalescing to handle falsy but defined values correctly
    const hook = module.default ?? module[name] ?? module;

    // Validate that we got something usable
    if (!hook) {
      throw new Error(`Hook module "${name}" exports no valid hook (default, named, or module itself is null/undefined)`);
    }

    loadedHooks.set(name, hook);
    loadingPromises.delete(name);
    return hook;
  }).catch(error => {
    console.error(`Failed to load hook "${name}":`, error);
    loadingPromises.delete(name);
    throw error;
  });

  loadingPromises.set(name, loadPromise);
  return await loadPromise;
}

/**
 * Create a lazy-loading hook wrapper
 * @param {string} name - Hook name for debugging
 * @param {Function} loader - () => import('./path/to/hook')
 * @returns {Object} Lazy hook that loads on first mount
 */
export function lazyHook(name, loader) {
  return {
    __lazyHook: name,
    __actualHook: null,
    __loading: false,
    __destroyed: false,
    __loadError: null,

    async mounted() {
      // Prevent duplicate initialization if mounted multiple times during load
      if (this.__loading) {
        console.warn(`Hook "${name}" mounted while still loading, skipping duplicate initialization`);
        return;
      }

      this.__loading = true;
      this.__destroyed = false;

      try {
        const hook = await loadHook(name, loader);

        // Check if destroyed while loading - abort if so
        if (this.__destroyed) {
          console.debug(`Hook "${name}" destroyed during load, aborting initialization`);
          return;
        }

        // Validate loaded hook
        const actualHook = typeof hook === 'function' ? new hook() : hook;
        if (!actualHook || typeof actualHook !== 'object') {
          throw new Error(`Invalid hook module for "${name}": expected object, got ${typeof actualHook}`);
        }

        this.__actualHook = actualHook;

        // Transfer LiveView context
        Object.assign(this.__actualHook, {
          el: this.el,
          pushEvent: this.pushEvent.bind(this),
          pushEventTo: this.pushEventTo.bind(this),
          handleEvent: this.handleEvent.bind(this),
          upload: this.upload?.bind(this),
          uploadTo: this.uploadTo?.bind(this)
        });

        // Call mounted if it exists
        if (this.__actualHook.mounted) {
          this.__actualHook.mounted.call(this.__actualHook);
        }

        // Emit success telemetry
        window.dispatchEvent(new CustomEvent('tymeslot:hook:loaded', {
          detail: { hook: name, success: true }
        }));
      } catch (error) {
        this.__loadError = error;
        console.error(`Failed to initialize lazy hook "${name}":`, error);

        // Emit failure telemetry
        window.dispatchEvent(new CustomEvent('tymeslot:hook:loaded', {
          detail: { hook: name, success: false, error: error.message }
        }));

        // Could push error event to LiveView for user notification
        if (this.pushEvent) {
          this.pushEvent('hook-load-error', { hook: name, error: error.message });
        }
      } finally {
        this.__loading = false;
      }
    },

    updated() {
      // Silently skip if hook failed to load or is still loading
      if (this.__actualHook && this.__actualHook.updated) {
        this.__actualHook.updated.call(this.__actualHook);
      }
    },

    destroyed() {
      // Signal to abort any in-progress loading
      this.__destroyed = true;

      // Clean up actual hook if it was loaded
      if (this.__actualHook && this.__actualHook.destroyed) {
        this.__actualHook.destroyed.call(this.__actualHook);
      }

      // Clear references to prevent memory leaks
      this.__actualHook = null;
    },

    disconnected() {
      if (this.__actualHook && this.__actualHook.disconnected) {
        this.__actualHook.disconnected.call(this.__actualHook);
      }
    },

    reconnected() {
      if (this.__actualHook && this.__actualHook.reconnected) {
        this.__actualHook.reconnected.call(this.__actualHook);
      }
    }
  };
}
