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
    // and re-apply the revealed state so the toggle survives re-renders.
    this.applyState();
  },

  destroyed() {
    if (this.button && this.clickHandler) {
      this.button.removeEventListener('click', this.clickHandler);
    }
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
    const input = this.input();
    // Scoped to this hook's own container, so the confirm-password field does
    // not tick the checklist that belongs to the password field above it.
    const list = this.el.querySelector('#password-requirements');
    if (!input || !list) return;

    // The rules and their patterns come from the server (PasswordValidator),
    // so this checklist cannot claim a different set to the one enforced.
    const rules = Array.from(list.querySelectorAll('[data-password-rule]'))
      .map((element) => {
        try {
          return { element, pattern: new RegExp(element.dataset.passwordPattern) };
        } catch (error) {
          console.error('Unusable password rule pattern', element.dataset.passwordPattern, error);
          return null;
        }
      })
      .filter(Boolean);

    input.addEventListener('input', () => {
      rules.forEach(({ element, pattern }) =>
        updateRequirement(element, pattern.test(input.value))
      );
    });
  },
};

function updateRequirement(element, isValid) {
  if (!element) return;
  const icon = element.querySelector('svg');
  if (isValid) {
    element.classList.remove('text-gray-500');
    element.classList.add('text-green-500');
    if (icon) {
      icon.innerHTML =
        '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />';
    }
  } else {
    element.classList.remove('text-green-500');
    element.classList.add('text-gray-500');
    if (icon) {
      icon.innerHTML = '<circle cx="12" cy="12" r="10" stroke-width="2"/>';
    }
  }
}

export { PasswordToggle };
