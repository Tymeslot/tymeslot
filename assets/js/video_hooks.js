// Video management hooks for LiveView
// Handles auth video optimization and rhythm video crossfade functionality

const getConnectionInfo = () =>
  navigator.connection || navigator.mozConnection || navigator.webkitConnection;

const isSlowConnection = (connection) => {
  if (!connection) return false;

  if (connection.saveData) return true;

  const effectiveType = connection.effectiveType || '';
  if (effectiveType === 'slow-2g' || effectiveType === '2g') return true;

  // Use RTT/downlink to catch slow WiFi or poor networks regardless of type.
  const downlink = typeof connection.downlink === 'number' ? connection.downlink : null;
  const rtt = typeof connection.rtt === 'number' ? connection.rtt : null;

  if (downlink !== null && downlink < 1.5) return true;
  if (rtt !== null && rtt > 300) return true;

  return false;
};

const setupConnectionFallback = (connection, onSlow) => {
  if (!connection) return null;

  const handler = () => {
    if (isSlowConnection(connection)) {
      onSlow();
    }
  };

  if (typeof connection.addEventListener === 'function') {
    connection.addEventListener('change', handler);
    return () => connection.removeEventListener('change', handler);
  }

  if ('onchange' in connection) {
    const previousHandler = connection.onchange;
    const combinedHandler = function(event) {
      if (typeof previousHandler === 'function') {
        previousHandler.call(connection, event);
      }
      handler();
    };
    connection.onchange = combinedHandler;
    return () => {
      if (connection.onchange === combinedHandler) {
        connection.onchange = previousHandler || null;
      }
    };
  }

  return null;
};

const stopVideoPlayback = (video) => {
  if (!video) return;

  try { video.pause && video.pause(); } catch (e) {}
  try { video.removeAttribute && video.removeAttribute('autoplay'); } catch (e) {}
  try { video.preload = 'none'; } catch (e) {}
};

// Quill video hook - simple video background with fallback
export const QuillVideo = {
  mounted() {
    // CSS already hides video in embedded context; skip JS overhead entirely.
    if (document.documentElement.hasAttribute('data-embedded')) return;

    const container = this.el;
    const video = container.querySelector('video');

    if (!video) return;

    // Check for reduced motion preference
    const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (prefersReducedMotion) {
      video.style.display = 'none';
      return;
    }

    // Handle video loading
    video.addEventListener('loadedmetadata', function() {
      video.style.opacity = '1';
    });

    // Handle video errors by falling back to gradient/image background
    video.addEventListener('error', function() {
      video.style.display = 'none';
    });

    const applyFallback = () => {
      stopVideoPlayback(video);
      video.style.display = 'none';
      container.classList.add('fallback');
    };

    // Connection-aware loading
    const connection = getConnectionInfo();
    if (isSlowConnection(connection)) {
      applyFallback();
    }

    this._quillConnectionCleanup = setupConnectionFallback(connection, applyFallback);

    // Battery-aware loading
    if ('getBattery' in navigator) {
      navigator.getBattery().then(function(battery) {
        if (battery.level < 0.3) {
          video.removeAttribute('autoplay');
        }
      });
    }

    this._quillVideo = video;
  },
  destroyed() {
    try { this._quillConnectionCleanup && this._quillConnectionCleanup(); } catch (e) {}
    try { this._quillVideo && this._quillVideo.pause && this._quillVideo.pause(); } catch (e) {}
    this._quillVideo = null;
    this._quillConnectionCleanup = null;
  }
};

// Auth video optimization hook - handles both single video and dual video crossfade
export const AuthVideo = {
  mounted() {
    const container = document.getElementById('auth-video-container');
    const singleVideo = document.getElementById('auth-background-video');
    const video1 = document.getElementById('auth-background-video-1');
    const video2 = document.getElementById('auth-background-video-2');

    if (!container) return;

    // Check for reduced motion preference
    const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (prefersReducedMotion) {
      if (singleVideo) singleVideo.style.display = 'none';
      if (video1) video1.style.display = 'none';
      if (video2) video2.style.display = 'none';
      container.classList.add('fallback');
      return;
    }

    const applyFallback = () => {
      stopVideoPlayback(singleVideo);
      stopVideoPlayback(video1);
      stopVideoPlayback(video2);
      if (singleVideo) singleVideo.style.display = 'none';
      if (video1) video1.style.display = 'none';
      if (video2) video2.style.display = 'none';
      container.classList.add('fallback');
    };

    // Connection-aware loading
    const connection = getConnectionInfo();
    if (isSlowConnection(connection)) {
      applyFallback();
      return;
    }

    // Handle single video case
    if (singleVideo && !video1 && !video2) {
      this._authConnectionCleanup = setupConnectionFallback(connection, applyFallback);
      singleVideo.addEventListener('loadedmetadata', function() {
        singleVideo.style.opacity = '1';
      });
      singleVideo.addEventListener('error', function() {
        applyFallback();
      });
      return;
    }

    // Handle dual video crossfade case — pass connection so it isn't re-fetched
    if (video1 && video2) {
      this.initAuthVideoCrossfade(container, video1, video2, connection);
    }
  },

  initAuthVideoCrossfade(container, video1, video2, connection) {
    let currentVideo = video1;
    let nextVideo = video2;
    let isTransitioning = false;

    // Tracks the video currently being monitored so listeners can be removed
    // before new ones are added on each crossfade cycle.
    this._authMonitor = { video: null, timeupdate: null, ended: null };

    const isSmallScreen = window.innerWidth <= 768;

    const applyFallback = () => {
      stopVideoPlayback(video1);
      stopVideoPlayback(video2);
      video1.style.display = 'none';
      video2.style.display = 'none';
      container.classList.add('fallback');
    };

    this._authConnectionCleanup = setupConnectionFallback(connection, applyFallback);

    // Select appropriate video quality based on screen size
    if (isSmallScreen) {
      [{ el: video1, sources: video1.querySelectorAll('source') },
       { el: video2, sources: video2.querySelectorAll('source') }].forEach(({ el, sources }) => {
        sources.forEach(source => {
          const src = source.getAttribute('src');
          if (src && src.includes('-mobile')) el.src = src;
        });
      });
    }

    // Battery-aware loading
    if ('getBattery' in navigator) {
      navigator.getBattery().then(function(battery) {
        if (battery.level < 0.3) {
          video1.removeAttribute('autoplay');
          video2.removeAttribute('autoplay');
        }
      });
    }

    // Error handling — if either video fails, fall back completely
    [video1, video2].forEach((video) => {
      video.addEventListener('error', function() {
        applyFallback();
      });
    });

    // Crossfade functionality
    const startCrossfade = () => {
      if (isTransitioning) return;

      isTransitioning = true;

      nextVideo.currentTime = 0;
      nextVideo.classList.remove('inactive');
      nextVideo.classList.add('crossfade-in');

      nextVideo.play().catch(() => {});

      // Complete transition after 800ms (matching CSS transition duration)
      setTimeout(function() {
        currentVideo.classList.remove('active');
        currentVideo.classList.add('inactive');
        currentVideo.pause();

        nextVideo.classList.remove('crossfade-in');
        nextVideo.classList.add('active');

        const temp = currentVideo;
        currentVideo = nextVideo;
        nextVideo = temp;

        isTransitioning = false;
        setupVideoMonitoring();
      }, 800);
    };

    // Monitor current video for crossfade timing.
    // Removes previous listeners before adding new ones to prevent accumulation
    // across crossfade cycles.
    const setupVideoMonitoring = () => {
      const m = this._authMonitor;
      if (m.video) {
        if (m.timeupdate) m.video.removeEventListener('timeupdate', m.timeupdate);
        if (m.ended) m.video.removeEventListener('ended', m.ended);
      }

      m.timeupdate = function() {
        if (isTransitioning) return;
        const timeLeft = currentVideo.duration - currentVideo.currentTime;
        if (timeLeft <= 1.0 && timeLeft > 0.9) startCrossfade();
      };

      m.ended = function() {
        if (!isTransitioning) startCrossfade();
      };

      m.video = currentVideo;
      currentVideo.addEventListener('timeupdate', m.timeupdate);
      currentVideo.addEventListener('ended', m.ended);
    };

    setupVideoMonitoring();

    // Pause/resume based on visibility
    const observer = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          if (currentVideo.paused) currentVideo.play().catch(() => {});
        } else {
          if (!currentVideo.paused) currentVideo.pause();
          if (!nextVideo.paused && !nextVideo.classList.contains('inactive')) nextVideo.pause();
        }
      });
    });

    observer.observe(container);
    this._observer = observer;
  },

  destroyed() {
    try { this._observer && this._observer.disconnect(); } catch (e) {}
    if (this._authMonitor) {
      const { video, timeupdate, ended } = this._authMonitor;
      try { if (video && timeupdate) video.removeEventListener('timeupdate', timeupdate); } catch (e) {}
      try { if (video && ended) video.removeEventListener('ended', ended); } catch (e) {}
    }
    ['auth-background-video', 'auth-background-video-1', 'auth-background-video-2'].forEach(id => {
      const v = document.getElementById(id);
      try { v && v.pause && v.pause(); } catch (e) {}
    });
    try { this._authConnectionCleanup && this._authConnectionCleanup(); } catch (e) {}
    this._observer = null;
    this._authMonitor = null;
    this._authConnectionCleanup = null;
  }
};

// Rhythm video crossfade hook
export const RhythmVideo = {
  mounted() {
    // CSS already hides video in embedded context; skip JS overhead entirely.
    if (document.documentElement.hasAttribute('data-embedded')) return;

    const video1 = document.getElementById('rhythm-background-video-1');
    const video2 = document.getElementById('rhythm-background-video-2');

    if (!video1 || !video2) return;

    // Check for reduced motion preference
    const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (prefersReducedMotion) {
      video1.style.display = 'none';
      video2.style.display = 'none';
      return;
    }

    const isSmallScreen = window.innerWidth <= 768;

    const applyFallback = () => {
      stopVideoPlayback(video1);
      stopVideoPlayback(video2);
      video1.style.display = 'none';
      video2.style.display = 'none';
    };

    const connection = getConnectionInfo();
    if (isSlowConnection(connection)) {
      applyFallback();
      return;
    }

    this._rhythmConnectionCleanup = setupConnectionFallback(connection, applyFallback);

    // Select appropriate video quality based on screen size
    if (isSmallScreen) {
      [{ el: video1, sources: video1.querySelectorAll('source') },
       { el: video2, sources: video2.querySelectorAll('source') }].forEach(({ el, sources }) => {
        sources.forEach(source => {
          const src = source.getAttribute('src');
          if (src && src.includes('-mobile')) el.src = src;
        });
      });
    }

    // Video crossfade logic
    let currentVideo = video1;
    let isTransitioning = false;

    // Tracks the video currently being monitored so listeners can be removed
    // before new ones are added on each crossfade cycle.
    this._rhythmMonitor = { video: null, timeupdate: null, ended: null };

    // Error handling — if either video fails, fall back completely
    [video1, video2].forEach(video => {
      video.addEventListener('error', function() {
        applyFallback();
      });
    });

    // Crossfade function
    const startCrossfade = () => {
      if (isTransitioning) return;
      isTransitioning = true;

      const nextVideo = currentVideo === video1 ? video2 : video1;

      nextVideo.currentTime = 0;
      nextVideo.style.opacity = '0';
      nextVideo.style.display = 'block';

      nextVideo.play().then(() => {
        // Crossfade transition
        setTimeout(() => {
          nextVideo.style.transition = 'opacity 1s ease-in-out';
          nextVideo.style.opacity = '1';

          currentVideo.style.transition = 'opacity 1s ease-in-out';
          currentVideo.style.opacity = '0';

          setTimeout(() => {
            currentVideo.style.display = 'none';
            currentVideo.pause();
            currentVideo = nextVideo;
            isTransitioning = false;
            setupVideoMonitoring();
          }, 1000);
        }, 100);
      }).catch(() => {
        isTransitioning = false;
      });
    };

    // Monitor video progress for crossfade timing.
    // Removes previous listeners before adding new ones to prevent accumulation
    // across crossfade cycles.
    const setupVideoMonitoring = () => {
      const m = this._rhythmMonitor;
      if (m.video) {
        if (m.timeupdate) m.video.removeEventListener('timeupdate', m.timeupdate);
        if (m.ended) m.video.removeEventListener('ended', m.ended);
      }

      m.timeupdate = function() {
        if (isTransitioning) return;
        const timeRemaining = currentVideo.duration - currentVideo.currentTime;
        if (timeRemaining <= 1.0 && timeRemaining > 0.9) startCrossfade();
      };

      m.ended = function() {
        if (!isTransitioning) startCrossfade();
      };

      m.video = currentVideo;
      currentVideo.addEventListener('timeupdate', m.timeupdate);
      currentVideo.addEventListener('ended', m.ended);
    };

    // Start first video
    video1.play().catch(function(error) {
      // Try to play on first user interaction (autoplay policy)
      const clickHandler = function() {
        video1.play().catch(() => {});
      };
      document.addEventListener('click', clickHandler, { once: true });
      this._rhythmClickHandler = clickHandler;
    }.bind(this));

    setupVideoMonitoring();

    // Pause/resume based on visibility
    const container = video1.closest('.video-background-container') || video1.parentElement;
    if (container) {
      const observer = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
          if (entry.isIntersecting) {
            if (currentVideo.paused) currentVideo.play().catch(() => {});
          } else {
            if (!currentVideo.paused) currentVideo.pause();
          }
        });
      });
      observer.observe(container);
      this._rhythmObserver = observer;
    }

    this._rhythmVideoElements = { video1, video2 };
  },

  destroyed() {
    try { this._rhythmObserver && this._rhythmObserver.disconnect(); } catch (e) {}
    if (this._rhythmClickHandler) {
      try { document.removeEventListener('click', this._rhythmClickHandler); } catch (e) {}
      this._rhythmClickHandler = null;
    }
    if (this._rhythmMonitor) {
      const { video, timeupdate, ended } = this._rhythmMonitor;
      try { if (video && timeupdate) video.removeEventListener('timeupdate', timeupdate); } catch (e) {}
      try { if (video && ended) video.removeEventListener('ended', ended); } catch (e) {}
    }
    if (this._rhythmVideoElements) {
      const { video1, video2 } = this._rhythmVideoElements;
      try { video1 && video1.pause && video1.pause(); } catch (e) {}
      try { video2 && video2.pause && video2.pause(); } catch (e) {}
      this._rhythmVideoElements = null;
    }
    try { this._rhythmConnectionCleanup && this._rhythmConnectionCleanup(); } catch (e) {}
    this._rhythmObserver = null;
    this._rhythmMonitor = null;
    this._rhythmConnectionCleanup = null;
  }
};
