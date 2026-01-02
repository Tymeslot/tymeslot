// Clipboard copy hook
export const ClipboardCopy = {
  mounted() {
    this.handleEvent("copy-to-clipboard", ({ text }) => {
      this.copyToClipboard(text);
    });
  },

  copyToClipboard(text) {
    // Modern clipboard API
    if (navigator.clipboard) {
      navigator.clipboard.writeText(text).then(() => {
        // Successfully copied
      }).catch(() => {
        // Fallback for older browsers
        this.fallbackCopyTextToClipboard(text);
      });
    } else {
      // Fallback for older browsers
      this.fallbackCopyTextToClipboard(text);
    }
  },

  fallbackCopyTextToClipboard(text) {
    const textArea = document.createElement("textarea");
    textArea.value = text;
    textArea.style.position = "fixed";
    textArea.style.top = "-999999px";
    textArea.style.left = "-999999px";
    document.body.appendChild(textArea);
    textArea.focus();
    textArea.select();
    
    try {
      document.execCommand('copy');
      // Successfully copied via fallback
    } catch (err) {
      // Failed to copy - fail silently
    }
    
    document.body.removeChild(textArea);
  }
};