// UI interaction hooks for LiveView
// Handles user interactions like confirmations, external links, and page reloads

// Confirmation dialog hook
export const ConfirmDelete = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      const message = this.el.dataset.confirm || 'Are you sure?';
      if (!confirm(message)) {
        e.preventDefault();
        e.stopPropagation();
      }
    });
  }
};


// Page reload hook
export const PageReload = {
  mounted() {
    this.el.addEventListener('click', (e) => {
      e.preventDefault();
      window.location.reload();
    });
  }
};