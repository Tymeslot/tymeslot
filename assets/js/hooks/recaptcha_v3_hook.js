/**
 * Phoenix LiveView hook for reCAPTCHA v3 integration
 */
export const RecaptchaV3Hook = {
  mounted() {
    this.siteKey = this.el.dataset.siteKey;
    this.recaptchaAction = this.el.dataset.recaptchaAction || 'contact_form';
    this.eventName = this.el.dataset.recaptchaEvent || 'submit';
    this.paramRoot = this.el.dataset.recaptchaParamRoot || 'contact';
    this.requireToken = this.el.dataset.recaptchaRequireToken === 'true';
    this.recaptchaFailed = false;  // Track if reCAPTCHA failed to load
    this.loadRecaptcha();
  },

  loadRecaptcha() {
    if (window.grecaptcha) {
      this.setupFormInterception();
      return;
    }

    if (!this.siteKey) {
      console.warn('reCAPTCHA site key missing; skipping reCAPTCHA hook setup');
      return;
    }

    // Load reCAPTCHA script if not already loaded
    const script = document.createElement('script');
    script.src = `https://www.google.com/recaptcha/api.js?render=${this.siteKey}`;
    
    let scriptLoaded = false;
    
    script.onload = () => {
      scriptLoaded = true;
      window.grecaptcha.ready(() => {
        this.setupFormInterception();
      });
    };
    script.onerror = () => {
      this.handleRecaptchaLoadError();
    };
    script.onabort = () => {
      this.handleRecaptchaLoadError();
    };
    
    document.head.appendChild(script);
    
    // Fallback: if script hasn't loaded in 10 seconds, treat it as failure
    // This handles cases where the script URL loads but never fires onload
    setTimeout(() => {
      if (!scriptLoaded && !window.grecaptcha) {
        console.warn('reCAPTCHA script did not load within 10 seconds; treating as blocked');
        this.handleRecaptchaLoadError();
      }
    }, 10000);
  },

  handleRecaptchaLoadError() {
    console.error('Failed to load reCAPTCHA script (blocked by CSP, network, or extension). Signup will be unavailable.');
    this.recaptchaFailed = true;
    
    if (this.requireToken) {
      // For forms that require a token (like signup), prevent submission
      this.el.style.opacity = '0.6';
      this.el.style.pointerEvents = 'none';
      
      // Add error message to form
      const errorDiv = document.createElement('div');
      errorDiv.className = 'recaptcha-load-error-message';
      errorDiv.style.cssText = 'color: #dc2626; font-size: 0.875rem; margin-bottom: 1rem; padding: 0.75rem; background-color: #fee2e2; border: 1px solid #fecaca; border-radius: 0.375rem;';
      errorDiv.textContent = 'Security verification unavailable. Please refresh the page. If the problem persists, please contact support.';
      
      this.el.insertBefore(errorDiv, this.el.firstChild);
      
      // Also set a marker on the form so submission handler can detect this
      this.el.dataset.recaptchaLoadFailed = 'true';
    }
    
    // Set up form interception anyway to handle submission attempts
    this.setupFormInterception();
  },

  setupFormInterception() {
    const form = this.el;
    // Prevent double-binding if LiveView re-mounts this hook
    if (form.dataset.recaptchaBound === 'true') return;
    form.dataset.recaptchaBound = 'true';

    // Intercept form submission
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      event.stopPropagation();

      // If reCAPTCHA failed to load, mark the token as "script_blocked" so server knows
      if (this.recaptchaFailed || !window.grecaptcha) {
        const hiddenField =
          form.querySelector(`input[name="${this.paramRoot}[g-recaptcha-response]"]`) ||
          form.querySelector('#g-recaptcha-response');

        if (hiddenField) {
          // Use a special marker so server can distinguish "JS disabled/blocked" from "network error"
          hiddenField.value = 'RECAPTCHA_SCRIPT_BLOCKED';
        }

        const formData = new FormData(form);
        const params = this.formDataToParams(formData);
        this.pushEvent(this.eventName, params);
        return;
      }

      // Execute reCAPTCHA before form submission
      window.grecaptcha.execute(this.siteKey, {action: this.recaptchaAction})
        .then((token) => {
          // Update hidden field with token
          const hiddenField =
            form.querySelector(`input[name="${this.paramRoot}[g-recaptcha-response]"]`) ||
            form.querySelector('#g-recaptcha-response');

          if (hiddenField) {
            hiddenField.value = token;
          }

          // Create form data and submit to LiveView
          const formData = new FormData(form);
          const params = this.formDataToParams(formData);

          // Trigger LiveView submit event
          this.pushEvent(this.eventName, params);
        })
        .catch((error) => {
          console.error('reCAPTCHA error:', error);

          if (this.requireToken) {
            // Hard requirement (e.g. signup): still submit to server so it can show an error,
            // but without a token so the server can block the operation.
            const formData = new FormData(form);
            const params = this.formDataToParams(formData);
            this.pushEvent(this.eventName, params);
            return;
          }

          // Fallback (e.g. contact): submit without token
          const formData = new FormData(form);
          const params = this.formDataToParams(formData);
          this.pushEvent(this.eventName, params);
        });
    });
  },

  formDataToParams(formData) {
    const params = {};
    for (const [key, value] of formData.entries()) {
      // Convert form field names to nested object structure expected by LiveView
      const matcher = new RegExp(`^${this.paramRoot}\\[(.+)\\]$`);
      const matches = key.match(matcher);
      if (matches) {
        if (!params[this.paramRoot]) params[this.paramRoot] = {};
        params[this.paramRoot][matches[1]] = value;
      } else {
        params[key] = value;
      }
    }
    return params;
  }
};