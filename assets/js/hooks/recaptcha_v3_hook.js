/**
 * Phoenix LiveView hook for reCAPTCHA v3 integration
 *
 * Proactively fetches a reCAPTCHA token when the form mounts and keeps it fresh.
 * This approach is compatible with phx-submit (including phx-target on components)
 * because the token is already populated in the hidden field before the form submits.
 */
export const RecaptchaV3Hook = {
  mounted() {
    this.siteKey = this.el.dataset.siteKey;
    this.recaptchaAction = this.el.dataset.recaptchaAction || 'contact_form';
    this.paramRoot = this.el.dataset.recaptchaParamRoot || 'contact';
    this.currentToken = null;
    this.tokenRefreshTimer = null;
    this.loadRecaptcha();
  },

  updated() {
    // Restore the token after LiveView re-renders the form (which resets the hidden field to "")
    if (this.currentToken) {
      this.setHiddenField(this.currentToken);
    }
  },

  destroyed() {
    if (this.tokenRefreshTimer) {
      clearTimeout(this.tokenRefreshTimer);
    }
  },

  loadRecaptcha() {
    if (!this.siteKey) {
      console.warn('reCAPTCHA site key missing; skipping reCAPTCHA hook setup');
      return;
    }

    if (window.grecaptcha) {
      // Script already loaded; wait for it to be ready then fetch token
      window.grecaptcha.ready(() => this.fetchToken());
      return;
    }

    // Load reCAPTCHA script
    const script = document.createElement('script');
    script.src = `https://www.google.com/recaptcha/api.js?render=${this.siteKey}`;

    let scriptLoaded = false;

    script.onload = () => {
      scriptLoaded = true;
      window.grecaptcha.ready(() => this.fetchToken());
    };
    script.onerror = () => this.handleRecaptchaLoadError();
    script.onabort = () => this.handleRecaptchaLoadError();

    document.head.appendChild(script);

    // Fallback: if script hasn't loaded in 10 seconds, treat it as failure
    setTimeout(() => {
      if (!scriptLoaded && !window.grecaptcha) {
        console.warn('reCAPTCHA script did not load within 10 seconds; treating as blocked');
        this.handleRecaptchaLoadError();
      }
    }, 10000);
  },

  handleRecaptchaLoadError() {
    console.error('Failed to load reCAPTCHA script (blocked by CSP, network, or extension).');
    // Set a special marker so the server can distinguish script-blocked from a missing token
    this.currentToken = 'RECAPTCHA_SCRIPT_BLOCKED';
    this.setHiddenField(this.currentToken);
  },

  fetchToken() {
    if (!window.grecaptcha || !this.siteKey) return;

    if (this.tokenRefreshTimer) {
      clearTimeout(this.tokenRefreshTimer);
      this.tokenRefreshTimer = null;
    }

    window.grecaptcha.execute(this.siteKey, { action: this.recaptchaAction })
      .then((token) => {
        this.currentToken = token;
        this.setHiddenField(token);
        // reCAPTCHA v3 tokens expire after 2 minutes; refresh at 90s to keep fresh
        this.tokenRefreshTimer = setTimeout(() => this.fetchToken(), 90 * 1000);
      })
      .catch((error) => {
        console.error('reCAPTCHA execute error:', error);
        // Leave currentToken as-is; server will reject empty token if reCAPTCHA is required
      });
  },

  setHiddenField(value) {
    const form = this.el;
    const hiddenField =
      form.querySelector(`input[name="${this.paramRoot}[g-recaptcha-response]"]`) ||
      form.querySelector('#g-recaptcha-response');

    if (hiddenField) {
      hiddenField.value = value;
    }
  }
};
