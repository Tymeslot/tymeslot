/**
 * Password visibility toggle.
 *
 * Implemented as a LiveView hook so the "revealed" state survives
 * morphdom patches. Without this, any LiveView re-render of the form
 * (e.g. phx-change validation) resets the input's `type` attribute
 * back to "password" and the toggle appears broken.
 */

const PasswordToggle = {
  mounted() {
    this.revealed = false;
    this.button = this.el.querySelector('[data-password-toggle-button]');
    if (this.button) {
      this.clickHandler = (event) => {
        event.preventDefault();
        this.revealed = !this.revealed;
        this.applyState();
      };
      this.button.addEventListener('click', this.clickHandler);
    }
    this.applyState();
    this.setupValidation();
  },

  updated() {
    // After a LiveView patch, re-resolve the input (it may be a new node)
    // and re-apply the revealed state so the toggle survives re-renders,
    // and watch and re-tick the checklist, which the patch may have replaced.
    this.applyState();
    this.observe();
    this.refreshRequirements({ afterPatch: true });
  },

  destroyed() {
    if (this.button && this.clickHandler) {
      this.button.removeEventListener('click', this.clickHandler);
    }
    this.observer?.disconnect();
  },

  input() {
    return this.el.querySelector('input[type="password"], input[type="text"]');
  },

  applyState() {
    const input = this.input();
    if (!input || !this.button) return;

    const type = this.revealed ? 'text' : 'password';
    if (input.getAttribute('type') !== type) {
      input.setAttribute('type', type);
    }

    const openEye = this.button.querySelector('[data-eye-open]');
    const closedEye = this.button.querySelector('[data-eye-closed]');
    if (openEye && closedEye) {
      openEye.classList.toggle('hidden', this.revealed);
      closedEye.classList.toggle('hidden', !this.revealed);
    }
  },

  setupValidation() {
    this.patterns = new Map();
    // Delegated to the hook's own container, which a patch never replaces,
    // while the input inside it may be. Scoped to this container too, so the
    // confirm-password field does not tick the password field's checklist.
    this.el.addEventListener('input', (event) => {
      if (event.target === this.input()) this.refreshRequirements();
    });

    // A patch that redraws the checklist puts back the server's all-unmet
    // markup without calling `updated()` (only the hook element's own changes
    // do), so the checklist is watched directly.
    this.observer = new MutationObserver(() => this.refreshRequirements({ afterPatch: true }));
    this.observe();
  },

  // (Re)attaches the observer to the checklist now in the page, which a patch
  // of the hook element itself may have replaced.
  observe() {
    const list = this.el.querySelector('#password-requirements');
    if (!this.observer || !list) return;
    this.observer.disconnect();
    this.observer.observe(list, { subtree: true, attributes: true, attributeFilter: ['class'] });
  },

  // Ticks each rule the field's current value meets. Runs on every keystroke
  // and after every patch: a patch puts back the server's all-unmet checklist,
  // which would otherwise stay wrong until the next keystroke. An empty field
  // after a patch keeps the server's markup, which is already all unmet.
  refreshRequirements({ afterPatch = false } = {}) {
    const input = this.input();
    const list = this.el.querySelector('#password-requirements');
    if (!input || !list || (afterPatch && input.value === '')) return;

    // Paused while ticking, so the observer does not answer its own changes.
    this.observer?.disconnect();
    // The rules and their patterns come from the server (PasswordValidator),
    // so this checklist cannot claim a different set to the one enforced.
    list.querySelectorAll('[data-password-rule]').forEach((element) => {
      const pattern = this.pattern(element.dataset.passwordPattern);
      if (pattern) updateRequirement(element, pattern.test(input.value));
    });
    this.observe();
  },

  pattern(source) {
    if (!this.patterns.has(source)) {
      let pattern = null;
      try {
        pattern = new RegExp(source);
      } catch (error) {
        console.error('Unusable password rule pattern', source, error);
      }
      this.patterns.set(source, pattern);
    }
    return this.patterns.get(source);
  },
};

function updateRequirement(element, isValid) {
  if (!element) return;
  // Both icons are rendered server-side; this only toggles which one shows.
  element.querySelector('[data-rule-met]')?.classList.toggle('hidden', !isValid);
  element.querySelector('[data-rule-unmet]')?.classList.toggle('hidden', isValid);
  element.classList.toggle('text-gray-500', !isValid);
  element.classList.toggle('text-green-500', isValid);
}

export { PasswordToggle };
