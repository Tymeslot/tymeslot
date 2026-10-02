/**
 * Phoenix LiveView hook for reCAPTCHA v3 integration
 *
 * Google is not contacted until the visitor starts using the form: the script
 * loads on the first `focusin` or `input` inside it, so a visitor who only
 * browses never sends Google anything. Loading on interaction rather than on
 * submit keeps the whole form-filling behaviour in view of reCAPTCHA's scoring.
 *
 * Once loaded, the hook fetches a token and keeps it fresh, so the token is
 * already in the hidden field when phx-submit serialises the form (including
 * phx-target on components). Refreshing pauses once the form has been idle for
 * a while and resumes on the next interaction.
 *
 * A form submitted before any token exists (autofill plus Enter, without ever
 * focusing a field) is held back: the submit is cancelled, the script is loaded
 * and executed, and the form is submitted again once a token, or the blocked
 * marker, is in place. The server rejects a missing token either way.
 */

// reCAPTCHA v3 tokens expire after two minutes; refresh well before that.
const TOKEN_REFRESH_MS = 90 * 1000;
// Stop refreshing once the visitor has not touched the form for this long.
const IDLE_PAUSE_MS = 5 * 60 * 1000;
// Treat the script as blocked if it has not loaded within this time.
const SCRIPT_LOAD_TIMEOUT_MS = 10 * 1000;

const SCRIPT_BLOCKED_MARKER = 'RECAPTCHA_SCRIPT_BLOCKED';

export const RecaptchaV3Hook = {
  mounted() {
    this.siteKey = this.el.dataset.siteKey;
    this.recaptchaAction = this.el.dataset.recaptchaAction || 'contact_form';
    this.paramRoot = this.el.dataset.recaptchaParamRoot || 'contact';
    this.currentToken = null;
    this.tokenRefreshTimer = null;
    this.loadTimeoutTimer = null;
    this.loadRequested = false;
    this.refreshPaused = false;
    this.lastInteractionAt = Date.now();
    // Set while a submit made before any token existed waits for one.
    this.pendingSubmit = null;
    this.resubmitting = false;

    this.handleInteraction = () => {
      this.lastInteractionAt = Date.now();

      if (!this.loadRequested) {
        this.loadRecaptcha();
      } else if (this.refreshPaused) {
        this.refreshPaused = false;
        this.fetchToken();
      }
    };

    // Each reCAPTCHA v3 token is single-use. The form may re-submit if the
    // first attempt errors (validation, slot conflict, transient failure), so
    // we regenerate the token on every submit event. By the time LiveView
    // re-renders the form with the error message, `currentToken` already
    // holds a fresh, unused token and `updated()` writes it back into the
    // hidden field, so the retry carries a different token and doesn't hit
    // Google's "timeout-or-duplicate" rejection.
    this.handleSubmit = (event) => this.onSubmit(event);

    this.el.addEventListener('focusin', this.handleInteraction);
    this.el.addEventListener('input', this.handleInteraction);
    this.el.addEventListener('submit', this.handleSubmit);
  },

  updated() {
    // Restore the token after LiveView re-renders the form (which resets the hidden field to "")
    if (this.currentToken) {
      this.setHiddenField(this.currentToken);
    }
  },

  destroyed() {
    this.clearRefreshTimer();

    if (this.loadTimeoutTimer) {
      clearTimeout(this.loadTimeoutTimer);
      this.loadTimeoutTimer = null;
    }

    this.el.removeEventListener('focusin', this.handleInteraction);
    this.el.removeEventListener('input', this.handleInteraction);
    this.el.removeEventListener('submit', this.handleSubmit);
  },

  onSubmit(event) {
    // Our own re-dispatch of a held submit: let LiveView have it.
    if (this.resubmitting) return;

    this.lastInteractionAt = Date.now();

    if (this.currentToken || !this.siteKey) {
      // The hidden field already carries a token (or reCAPTCHA is not set up
      // on this form): let the submit through and rotate the token for a retry.
      this.refreshPaused = false;
      this.fetchToken();
      return;
    }

    // No token yet. LiveView serialises the form synchronously in its own
    // submit listener, so letting this event through would post an empty
    // token. Hold it back until one exists.
    event.preventDefault();
    event.stopImmediatePropagation();

    if (this.pendingSubmit) return;

    this.pendingSubmit = { submitter: event.submitter || null };
    this.refreshPaused = false;

    if (this.loadRequested) {
      // The script is loading or loaded but no token has arrived yet.
      this.fetchToken();
    } else {
      this.loadRecaptcha();
    }
  },

  releasePendingSubmit() {
    if (!this.pendingSubmit) return;

    const { submitter } = this.pendingSubmit;
    this.pendingSubmit = null;

    if (!this.el.isConnected) return;

    this.resubmitting = true;
    try {
      if (submitter && submitter.form === this.el) {
        this.el.requestSubmit(submitter);
      } else {
        this.el.requestSubmit();
      }
    } finally {
      this.resubmitting = false;
    }
  },

  loadRecaptcha() {
    if (this.loadRequested) return;
    this.loadRequested = true;

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

    // Propagate the page's CSP nonce so grecaptcha can stamp it on the inline
    // scripts it injects at runtime; without it they are blocked once
    // script-src drops 'unsafe-inline'.
    const nonce = document.querySelector('meta[name="csp-nonce"]')?.content;
    if (nonce) {
      script.nonce = nonce;
      script.setAttribute('nonce', nonce);
    }

    let scriptLoaded = false;

    script.onload = () => {
      scriptLoaded = true;
      window.grecaptcha.ready(() => this.fetchToken());
    };
    script.onerror = () => this.handleRecaptchaLoadError();
    script.onabort = () => this.handleRecaptchaLoadError();

    document.head.appendChild(script);

    // Fallback: if script hasn't loaded in time, treat it as failure
    this.loadTimeoutTimer = setTimeout(() => {
      this.loadTimeoutTimer = null;
      if (!scriptLoaded && !window.grecaptcha) {
        console.warn('reCAPTCHA script did not load within 10 seconds; treating as blocked');
        this.handleRecaptchaLoadError();
      }
    }, SCRIPT_LOAD_TIMEOUT_MS);
  },

  handleRecaptchaLoadError() {
    console.error('Failed to load reCAPTCHA script (blocked by CSP, network, or extension).');
    // Set a special marker so the server can distinguish script-blocked from a missing token
    this.currentToken = SCRIPT_BLOCKED_MARKER;
    this.setHiddenField(this.currentToken);
    this.releasePendingSubmit();
  },

  fetchToken() {
    if (!window.grecaptcha || !this.siteKey) return;

    this.clearRefreshTimer();

    window.grecaptcha.execute(this.siteKey, { action: this.recaptchaAction })
      .then((token) => {
        this.currentToken = token;
        this.setHiddenField(token);
        this.tokenRefreshTimer = setTimeout(() => this.refreshToken(), TOKEN_REFRESH_MS);
        this.releasePendingSubmit();
      })
      .catch((error) => {
        console.error('reCAPTCHA execute error:', error);
        // Post whatever the field holds; the server rejects a missing token
        // with a visible error rather than leaving the visitor waiting.
        this.releasePendingSubmit();
      });
  },

  refreshToken() {
    this.tokenRefreshTimer = null;

    if (Date.now() - this.lastInteractionAt < IDLE_PAUSE_MS) {
      this.fetchToken();
      return;
    }

    // Idle: stop calling Google. The current token is about to expire, so
    // drop it; the next interaction fetches a fresh one, and a submit without
    // one is held back until it arrives.
    this.refreshPaused = true;
    this.currentToken = null;
    this.setHiddenField('');
  },

  clearRefreshTimer() {
    if (this.tokenRefreshTimer) {
      clearTimeout(this.tokenRefreshTimer);
      this.tokenRefreshTimer = null;
    }
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
