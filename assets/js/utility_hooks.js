// Utility hooks for LiveView
// Handles general utility functions like flash messages, scrolling, and focus

// Flash message hook for auto-dismiss functionality
export const Flash = {
  mounted() {
    // Auto-dismiss after 6 seconds
    this.timer = setTimeout(() => {
      if (this.el.dataset.close !== "false") {
        this.el.click();
      }
    }, 6000);
    
    // Trigger mounted event for additional handling if needed
    window.dispatchEvent(new CustomEvent("flash:mounted", { 
      detail: { id: this.el.id } 
    }));
  },
  
  destroyed() {
    clearTimeout(this.timer);
  }
};

// Auto-scroll to slots on mobile and tablet when slots are loaded
export const AutoScrollToSlots = {
  mounted() {
    this.handleSlotsUpdate = () => {
      // Scroll on mobile and tablet viewports (when layout is stacked)
      if (window.innerWidth < 1024) {
        // Check if slots have been loaded (not empty state)
        const hasSlots = this.el.querySelector('.space-y-3') || 
                        this.el.querySelector('.animate-spin') ||
                        this.el.querySelector('.text-yellow-200');
        
        if (hasSlots) {
          // Small delay to ensure DOM is fully updated
          setTimeout(() => {
            this.el.scrollIntoView({ 
              behavior: 'smooth', 
              block: 'start',
              inline: 'nearest' 
            });
          }, 100);
        }
      }
    };

    // Observe changes to the slots container
    this.observer = new MutationObserver(this.handleSlotsUpdate);
    this.observer.observe(this.el, { 
      childList: true, 
      subtree: true 
    });
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  }
};

// Auto-focus hook for input fields that need immediate focus
export const AutoFocus = {
  mounted() {
    // Focus the input element immediately
    this.el.focus();
    
    // Optional: Select all text if the input has a value
    if (this.el.value) {
      this.el.select();
    }
  }
};