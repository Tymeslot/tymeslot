export const EmbedPreview = {
  mounted() {
    this._cachedDataset = {};
    this.ensureEmbedScript();
    this.initEmbed();
  },
  updated() {
    const { username, baseUrl, embedType, isReady } = this.el.dataset;
    const prev = this._cachedDataset;

    if (
      username === prev.username &&
      baseUrl === prev.baseUrl &&
      embedType === prev.embedType &&
      isReady === prev.isReady
    ) {
      return;
    }

    if (this._modalRetryInterval) {
      clearInterval(this._modalRetryInterval);
      this._modalRetryInterval = null;
    }

    this.initEmbed();
  },
  destroyed() {
    if (this._modalRetryInterval) {
      clearInterval(this._modalRetryInterval);
    }
  },
  ensureEmbedScript() {
    if (!window.TymeslotBooking && !document.getElementById('tymeslot-embed-script')) {
      const { embedScriptUrl } = this.el.dataset;
      if (!embedScriptUrl) return;

      const script = document.createElement('script');
      script.id = 'tymeslot-embed-script';
      script.src = embedScriptUrl;
      script.async = true;
      document.head.appendChild(script);
    }
  },
  initEmbed() {
    const { username, baseUrl, embedType, isReady } = this.el.dataset;
    this._cachedDataset = { username, baseUrl, embedType, isReady };
    const effectiveBaseUrl = baseUrl || window.location.origin;
    const ready = isReady === 'true';

    // Clear container
    this.el.innerHTML = '';
    
    if (!ready) {
      this.renderDeactivatedFallback();
      return;
    }
    
    switch (embedType) {
      case 'popup':
        this.renderPopupPreview(username, effectiveBaseUrl);
        break;
      case 'link':
        this.renderLinkPreview(username, effectiveBaseUrl);
        break;
      case 'floating':
        this.renderFloatingPreview(username, effectiveBaseUrl);
        break;
      case 'inline':
      default:
        this.renderInlinePreview(username, effectiveBaseUrl);
    }
  },

  renderDeactivatedFallback() {
    const wrapper = document.createElement('div');
    wrapper.className = 'text-center p-8 w-full max-w-md mx-auto';
    
    wrapper.innerHTML = `
      <div class="mb-4 bg-slate-200 rounded-lg p-6 opacity-60 grayscale">
        <div class="h-4 bg-slate-300 rounded w-3/4 mx-auto mb-4"></div>
        <div class="h-4 bg-slate-300 rounded w-1/2 mx-auto"></div>
        <div class="mt-8 py-3 bg-slate-300 rounded-xl w-3/4 mx-auto"></div>
      </div>
      <p class="text-slate-500 text-sm font-medium italic">
        The preview is disabled because your booking link is currently deactivated.
      </p>
    `;
    
    this.el.appendChild(wrapper);
  },

  renderInlinePreview(username, baseUrl) {
    const iframe = this.createIframe(username, baseUrl);
    this.el.appendChild(iframe);
  },

  renderPopupPreview(username, baseUrl) {
    const wrapper = document.createElement('div');
    wrapper.className = 'text-center p-8 w-full';
    
    const button = document.createElement('button');
    button.textContent = 'Book a Meeting';
    
    const primaryColor = '#14b8a6';
    // Determine text color based on background brightness
    const textColor = this.getContrastColor(primaryColor);
    
    // Use inline styles to ensure visibility and override any dashboard leaks
    button.style.cssText = `
      display: inline-block;
      padding: 12px 24px;
      color: ${textColor} !important;
      background-color: ${primaryColor};
      font-weight: bold;
      border-radius: 12px;
      border: none;
      cursor: pointer;
      box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
      transition: all 0.2s ease;
    `;
    
    button.onmouseover = () => { button.style.transform = 'scale(1.05)'; };
    button.onmouseout = () => { button.style.transform = 'scale(1)'; };
    
    button.onclick = () => {
      this.openModal(username);
    };
    
    const hint = document.createElement('p');
    hint.textContent = 'Click to test the booking modal';
    hint.className = 'text-xs text-slate-400 mt-4';
    
    wrapper.appendChild(button);
    wrapper.appendChild(hint);
    this.el.appendChild(wrapper);
  },

  openModal(username) {
    if (window.TymeslotBooking) {
      window.TymeslotBooking.open(username);
    } else {
      // Retry for a moment if script is still loading
      let retries = 0;
      if (this._modalRetryInterval) clearInterval(this._modalRetryInterval);
      this._modalRetryInterval = setInterval(() => {
        if (window.TymeslotBooking) {
          window.TymeslotBooking.open(username);
          clearInterval(this._modalRetryInterval);
          this._modalRetryInterval = null;
        } else if (retries > 10) {
          alert('Booking widget is still loading. Please try again in a second.');
          clearInterval(this._modalRetryInterval);
          this._modalRetryInterval = null;
        }
        retries++;
      }, 200);
    }
  },

  renderLinkPreview(username, baseUrl) {
    const wrapper = document.createElement('div');
    wrapper.className = 'text-center p-8 w-full';

    const link = document.createElement('a');
    const linkUrl = new URL(`/${encodeURIComponent(username)}`, baseUrl);
    link.href = linkUrl.toString();
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.textContent = 'Schedule a meeting with me →';
    link.className = 'text-turquoise-600 underline font-medium hover:text-turquoise-700 transition-colors';
    
    const hint = document.createElement('p');
    hint.textContent = 'This direct link is only active when your account is ready';
    hint.className = 'text-xs text-slate-400 mt-4';
    
    wrapper.appendChild(link);
    wrapper.appendChild(hint);
    this.el.appendChild(wrapper);
  },

  renderFloatingPreview(username, baseUrl) {
    const wrapper = document.createElement('div');
    wrapper.className = 'relative w-full h-[400px] bg-white rounded-lg overflow-hidden border-2 border-slate-200';
    
    const primaryColor = '#14b8a6';
    // Determine icon color based on background brightness
    const iconColor = this.getContrastColor(primaryColor);
    
    // Mock website content
    wrapper.innerHTML = `
      <div class="p-6 space-y-4">
        <div class="flex items-center space-x-2 mb-8">
          <div class="w-8 h-8 bg-slate-200 rounded-full"></div>
          <div class="h-4 bg-slate-200 rounded w-32"></div>
        </div>
        <div class="h-8 bg-slate-100 rounded w-3/4"></div>
        <div class="h-4 bg-slate-50 rounded w-1/2"></div>
        <div class="grid grid-cols-2 gap-4 mt-8">
          <div class="h-32 bg-slate-50 rounded-xl"></div>
          <div class="h-32 bg-slate-50 rounded-xl"></div>
        </div>
      </div>
      <div class="absolute bottom-6 right-6">
        <div class="w-14 h-14 rounded-full shadow-2xl flex items-center justify-center cursor-pointer hover:scale-110 transition-transform active:scale-90" 
             style="background-color: ${primaryColor}; color: ${iconColor}">
          <svg class="w-7 h-7" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"></path>
          </svg>
        </div>
      </div>
    `;
    
    const button = wrapper.querySelector('div.absolute div');
    button.onclick = () => {
      this.openModal(username);
    };
    
    this.el.appendChild(wrapper);
  },

  createIframe(username, baseUrl) {
    const iframe = document.createElement('iframe');
    const url = new URL(`/${encodeURIComponent(username)}`, baseUrl);
    url.searchParams.set('preview', 'true');
    // Cache buster to force reload when settings change
    url.searchParams.set('v', String(Date.now()));

    iframe.src = url.toString();
    iframe.setAttribute('title', 'Booking Preview');
    iframe.style.width = '100%';
    iframe.style.height = '100%';
    iframe.style.minHeight = '400px';
    iframe.style.border = 'none';
    iframe.style.borderRadius = '8px';
    return iframe;
  },

  getContrastColor(hexcolor) {
    // If no color provided, default to white text for the turquoise default
    if (!hexcolor) return 'white';
    
    // Remove the # if present
    const hex = hexcolor.replace('#', '');
    
    // Convert to RGB
    const r = parseInt(hex.substr(0, 2), 16);
    const g = parseInt(hex.substr(2, 2), 16);
    const b = parseInt(hex.substr(4, 2), 16);
    
    // Calculate brightness (YIQ formula)
    const yiq = ((r * 299) + (g * 587) + (b * 114)) / 1000;
    
    // Return black for light backgrounds, white for dark backgrounds
    return (yiq >= 128) ? 'black' : 'white';
  }
};

export default EmbedPreview;
