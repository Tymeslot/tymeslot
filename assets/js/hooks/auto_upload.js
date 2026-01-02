// Generic hook for auto-uploading files when selected
export const AutoUpload = {
  mounted() {
    // Add a small delay to ensure forms are fully rendered
    setTimeout(() => {
      this.setupAutoUpload();
    }, 100);
    
    // Listen for upload completion to clear the file input
    this.handleEvent("upload-complete", () => {
      this.clearFileInputs();
    });
  },
  
  updated() {
    // Re-attach listeners when the DOM updates with a small delay
    setTimeout(() => {
      this.setupAutoUpload();
    }, 100);
  },
  
  clearFileInputs() {
    const fileInputs = this.el.querySelectorAll('input[type="file"]');
    fileInputs.forEach(input => {
      input.value = '';
    });
  },
  
  setupAutoUpload() {
    // Remove any existing listeners to avoid duplicates
    if (this.fileChangeHandlers) {
      this.fileChangeHandlers.forEach(({input, handler}) => {
        input.removeEventListener('change', handler);
      });
    }
    
    this.fileChangeHandlers = [];
    
    // Find all file inputs and their associated submit buttons
    const forms = this.el.querySelectorAll('form[data-auto-upload="true"]');
    
    forms.forEach(form => {
      const fileInput = form.querySelector('input[type="file"]');
      const submitBtn = form.querySelector('button[type="submit"]');
      
      if (fileInput && submitBtn) {
        const handler = (e) => {
          if (e.target.files && e.target.files.length > 0) {
            // Check if we're not already uploading
            const isUploading = form.querySelector('.animate-spin');
            if (!isUploading) {
              // Wait a moment for LiveView to register the file
              setTimeout(() => {
                // Click the submit button to trigger upload
                submitBtn.click();
              }, 100);
            }
          }
        };
        
        fileInput.addEventListener('change', handler);
        this.fileChangeHandlers.push({input: fileInput, handler});
      }
    });
  },
  
  destroyed() {
    // Clean up event listeners
    if (this.fileChangeHandlers) {
      this.fileChangeHandlers.forEach(({input, handler}) => {
        input.removeEventListener('change', handler);
      });
    }
  }
};