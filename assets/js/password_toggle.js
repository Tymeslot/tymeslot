/**
 * Password visibility toggle functionality
 * 
 * This module provides functionality to toggle password visibility in forms
 * and validate password requirements.
 */

/**
 * Toggle password visibility function for direct use with onclick attribute
 * 
 * @param {HTMLElement} button - The button element that was clicked
 */
function togglePasswordVisibility(button) {
  const container = button.closest('.password-container');
  if (!container) return;
  
  const input = container.querySelector('input[type="password"], input[type="text"]');
  if (!input) return;

  // Toggle password visibility
  const type = input.getAttribute('type') === 'password' ? 'text' : 'password';
  input.setAttribute('type', type);
  
  // Toggle eye icon visibility
  const openEye = button.querySelector('.eye-open');
  const closedEye = button.querySelector('.eye-closed');
  
  if (openEye && closedEye) {
    if (type === 'text') {
      openEye.classList.add('hidden');
      closedEye.classList.remove('hidden');
    } else {
      openEye.classList.remove('hidden');
      closedEye.classList.add('hidden');
    }
  }
}

// Add togglePasswordVisibility to the global window object
// so it can be called from inline onclick handlers
if (typeof window !== 'undefined') {
  window.togglePasswordVisibility = togglePasswordVisibility;
}

/**
 * Sets up password toggle functionality for a specific input/toggle pair
 * 
 * @param {string} inputId - The ID of the password input field
 * @param {string} toggleId - The ID of the toggle button/icon
 */
function setupPasswordToggle(inputId, toggleId) {
  const passwordToggle = document.getElementById(toggleId);
  const passwordInput = document.getElementById(inputId);

  if (passwordToggle && passwordInput) {
    passwordToggle.addEventListener('click', function() {
      const type = passwordInput.getAttribute('type') === 'password' ? 'text' : 'password';
      passwordInput.setAttribute('type', type);
      
      // Toggle the eye icon
      const eyeIcon = passwordToggle.querySelector('svg');
      if (type === 'password') {
        eyeIcon.innerHTML = `
          <path d="M10 12a2 2 0 100-4 2 2 0 000 4z" />
          <path fill-rule="evenodd" d="M.458 10C1.732 5.943 5.522 3 10 3s8.268 2.943 9.542 7c-1.274 4.057-5.064 7-9.542 7S1.732 14.057.458 10zM14 10a4 4 0 11-8 0 4 4 0 018 0z" clip-rule="evenodd" />
        `;
      } else {
        eyeIcon.innerHTML = `
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21" />
        `;
      }
    });
  }
}

/**
 * Sets up password validation with visual feedback
 */
function setupPasswordValidation() {
  const passwordInput = document.getElementById('password-input');
  if (passwordInput && document.getElementById('req-length')) {
    passwordInput.addEventListener('input', function() {
      const password = this.value;
      
      // Update requirement indicators
      updateRequirement('length', password.length >= 8);
      updateRequirement('lowercase', /[a-z]/.test(password));
      updateRequirement('uppercase', /[A-Z]/.test(password));
      updateRequirement('number', /[0-9]/.test(password));
    });
  }
}

/**
 * Updates a specific requirement indicator based on validation
 * 
 * @param {string} requirement - The requirement identifier
 * @param {boolean} isValid - Whether the requirement is met
 */
function updateRequirement(requirement, isValid) {
  const element = document.getElementById(`req-${requirement}`);
  if (!element) return;
  
  const icon = element.querySelector('svg');
  
  if (isValid) {
    element.classList.remove('text-gray-500');
    element.classList.add('text-green-500');
    icon.innerHTML = `
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
    `;
  } else {
    element.classList.remove('text-green-500');
    element.classList.add('text-gray-500');
    icon.innerHTML = `
      <circle cx="12" cy="12" r="10" stroke-width="2"/>
    `;
  }
}

/**
 * Initialize password toggle for non-LiveView pages
 */
function initPasswordToggle() {
  document.addEventListener('DOMContentLoaded', function() {
    setupPasswordToggle('password-input', 'password-toggle');
    setupPasswordToggle('confirm-password-input', 'confirm-password-toggle');
    setupPasswordValidation();
  });
}

/**
 * LiveView Hook for password toggle functionality
 */
const PasswordToggle = {
  mounted() {
    setupPasswordToggle('password-input', 'password-toggle');
    setupPasswordToggle('confirm-password-input', 'confirm-password-toggle');
    setupPasswordValidation();
  }
};

export {
  PasswordToggle,
  initPasswordToggle,
  setupPasswordToggle,
  setupPasswordValidation,
  updateRequirement,
  togglePasswordVisibility
};
