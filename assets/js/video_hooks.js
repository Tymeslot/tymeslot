// Video management hooks for LiveView
// Handles auth video optimization and rhythm video crossfade functionality

// Quill video hook - simple video background with fallback
export const QuillVideo = {
  mounted() {
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
      console.log('Quill video failed to load, using fallback background');
      video.style.display = 'none';
      // The CSS background on the container will take over
    });
    
    // Connection-aware loading
    const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    if (connection && (connection.effectiveType === 'slow-2g' || connection.effectiveType === '2g' || connection.saveData)) {
      video.style.display = 'none';
    }
    
    // Battery-aware loading
    if ('getBattery' in navigator) {
      navigator.getBattery().then(function(battery) {
        if (battery.level < 0.3) {
          video.removeAttribute('autoplay');
        }
      });
    }

    // Save element for cleanup
    this._quillVideo = video;
  },
  destroyed() {
    try { this._quillVideo && this._quillVideo.pause && this._quillVideo.pause(); } catch (e) {}
    this._quillVideo = null;
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
    
    // Handle single video case
    if (singleVideo && !video1 && !video2) {
      singleVideo.addEventListener('loadedmetadata', function() {
        singleVideo.style.opacity = '1';
      });
      
      singleVideo.addEventListener('error', function() {
        container.classList.add('fallback');
      });
      return;
    }
    
    // Handle dual video crossfade case
    if (video1 && video2) {
      this.initAuthVideoCrossfade(container, video1, video2);
    }
  },
  
  initAuthVideoCrossfade(container, video1, video2) {
    let currentVideo = video1;
    let nextVideo = video2;
    let isTransitioning = false;

    // Connection-aware video loading
    const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    let shouldLoadVideo = true;

    if (connection) {
      if (connection.effectiveType === 'slow-2g' || connection.effectiveType === '2g') {
        shouldLoadVideo = false;
      }
      if (connection.saveData) {
        shouldLoadVideo = false;
      }
    }

    // Mobile detection
    const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
    const isSmallScreen = window.innerWidth <= 768;

    // Allow videos on mobile but with optimized sources
    if (!shouldLoadVideo) {
      video1.style.display = 'none';
      video2.style.display = 'none';
      container.classList.add('fallback');
      return;
    }

    // Select appropriate video quality based on device and connection
    if (isMobile || isSmallScreen) {
      // Use mobile-optimized video sources
      const sources1 = video1.querySelectorAll('source');
      const sources2 = video2.querySelectorAll('source');
      
      // Prioritize mobile sources by reordering or updating src
      sources1.forEach(source => {
        const src = source.getAttribute('src');
        if (src && src.includes('-mobile')) {
          video1.src = src;
        }
      });
      
      sources2.forEach(source => {
        const src = source.getAttribute('src');
        if (src && src.includes('-mobile')) {
          video2.src = src;
        }
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

    // Error handling for both videos
    [video1, video2].forEach((video, index) => {
      video.addEventListener('error', function(error) {
        console.log(`Auth video ${index + 1} failed to load, using fallback:`, error);
        video1.style.display = 'none';
        video2.style.display = 'none';
        container.classList.add('fallback');
      });

      video.addEventListener('loadstart', function() {
        console.log(`Auth video ${index + 1} loading started`);
      });

      video.addEventListener('canplaythrough', function() {
        console.log(`Auth video ${index + 1} ready to play`);
      });
    });

    // Crossfade functionality
    const startCrossfade = () => {
      if (isTransitioning) return;
      
      isTransitioning = true;

      // Prepare next video
      nextVideo.currentTime = 0;
      nextVideo.classList.remove('inactive');
      nextVideo.classList.add('crossfade-in');

      // Start playing next video
      nextVideo.play().catch(e => {
        console.log('Auth next video play failed:', e);
      });

      // Complete transition after 800ms (matching CSS transition duration)
      setTimeout(function() {
        currentVideo.classList.remove('active');
        currentVideo.classList.add('inactive');
        currentVideo.pause();

        nextVideo.classList.remove('crossfade-in');
        nextVideo.classList.add('active');

        // Switch video references
        const temp = currentVideo;
        currentVideo = nextVideo;
        nextVideo = temp;

        isTransitioning = false;
        setupVideoMonitoring();
      }, 800);
    };

    // Monitor current video for crossfade timing
    const setupVideoMonitoring = () => {
      currentVideo.addEventListener('timeupdate', function() {
        if (isTransitioning) return;
        
        const timeLeft = currentVideo.duration - currentVideo.currentTime;
        
        // Start crossfade 1 second before video ends
        if (timeLeft <= 1.0 && timeLeft > 0.9) {
          startCrossfade();
        }
      });

      // Backup trigger in case timeupdate doesn't fire precisely
      currentVideo.addEventListener('ended', function() {
        if (!isTransitioning) {
          startCrossfade();
        }
      });
    };

    // Initial setup
    setupVideoMonitoring();

    // Intersection Observer for performance
    const observer = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) {
          if (currentVideo.paused) {
            currentVideo.play().catch(e => {
              console.log('Auth current video autoplay failed:', e);
            });
          }
        } else {
          if (!currentVideo.paused) {
            currentVideo.pause();
          }
          if (!nextVideo.paused && !nextVideo.classList.contains('inactive')) {
            nextVideo.pause();
          }
        }
      });
    });

    observer.observe(container);
    // Store observer for cleanup
    this._observer = observer;
    this._authVideoElements = { container, currentVideo, nextVideo };
  },
  destroyed() {
    try { this._observer && this._observer.disconnect(); } catch (e) {}
    if (this._authVideoElements) {
      const { currentVideo, nextVideo } = this._authVideoElements;
      try { currentVideo && currentVideo.pause && currentVideo.pause(); } catch (e) {}
      try { nextVideo && nextVideo.pause && nextVideo.pause(); } catch (e) {}
    }
    this._observer = null;
    this._authVideoElements = null;
  }
};

// Rhythm video crossfade hook
export const RhythmVideo = {
  mounted() {
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

    // Connection-aware video loading
    const connection = navigator.connection || navigator.mozConnection || navigator.webkitConnection;
    let shouldLoadVideo = true;

    if (connection) {
      // Don't load video on slow connections
      if (connection.effectiveType === 'slow-2g' || connection.effectiveType === '2g') {
        shouldLoadVideo = false;
      }

      // Don't load video if data saver is enabled
      if (connection.saveData) {
        shouldLoadVideo = false;
      }
    }

    // Mobile detection
    const isMobile = /Android|webOS|iPhone|iPad|iPod|BlackBerry|IEMobile|Opera Mini/i.test(navigator.userAgent);
    const isSmallScreen = window.innerWidth <= 768;

    // Allow videos on mobile but with optimized sources
    if (!shouldLoadVideo) {
      video1.style.display = 'none';
      video2.style.display = 'none';
      return;
    }

    // Select appropriate video quality based on device and connection
    if (isMobile || isSmallScreen) {
      // Use mobile-optimized video sources
      const sources1 = video1.querySelectorAll('source');
      const sources2 = video2.querySelectorAll('source');
      
      // Prioritize mobile sources by reordering or updating src
      sources1.forEach(source => {
        const src = source.getAttribute('src');
        if (src && src.includes('-mobile')) {
          video1.src = src;
        }
      });
      
      sources2.forEach(source => {
        const src = source.getAttribute('src');
        if (src && src.includes('-mobile')) {
          video2.src = src;
        }
      });
    }

    // Video crossfade logic
    let currentVideo = video1;
    let isTransitioning = false;

    // Error handling for both videos
    [video1, video2].forEach(video => {
      video.addEventListener('error', function(error) {
        console.log('Video failed to load, using fallback:', error);
        video.style.display = 'none';
      });

      video.addEventListener('loadstart', function() {
        console.log('Video loading started');
      });

      video.addEventListener('canplaythrough', function() {
        console.log('Video ready to play');
      });
    });

    // Crossfade function
    function startCrossfade() {
      if (isTransitioning) return;
      isTransitioning = true;

      const nextVideo = currentVideo === video1 ? video2 : video1;
      
      // Prepare next video
      nextVideo.currentTime = 0;
      nextVideo.style.opacity = '0';
      nextVideo.style.display = 'block';
      
      // Start playing next video
      nextVideo.play().catch(error => {
        console.log('Next video play failed:', error);
        isTransitioning = false;
        return;
      });

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
    }

    // Monitor video progress for crossfade timing
    function setupVideoMonitoring() {
      currentVideo.addEventListener('timeupdate', function() {
        if (isTransitioning) return;
        
        const timeRemaining = currentVideo.duration - currentVideo.currentTime;
        // Start crossfade 1 second before video ends
        if (timeRemaining <= 1.0 && timeRemaining > 0.9) {
          startCrossfade();
        }
      });

      // Backup crossfade trigger on video end
      currentVideo.addEventListener('ended', function() {
        if (!isTransitioning) {
          startCrossfade();
        }
      });
    }

    // Start first video
    video1.play().catch(function(error) {
      console.log('Video autoplay failed:', error);
      // Try to play on first user interaction
      const clickHandler = function() {
        video1.play().catch(function(retryError) {
          console.log('Video play on interaction failed:', retryError);
        });
      };
      document.addEventListener('click', clickHandler, { once: true });
      // Save to remove on destroyed if needed (though once: true should auto-clean)
      this._rhythmClickHandler = clickHandler;
    }.bind(this));

    setupVideoMonitoring();

    // No IntersectionObserver here, but store refs for cleanup
    this._rhythmVideoElements = { video1, video2 };
  },
  destroyed() {
    if (this._rhythmClickHandler) {
      try { document.removeEventListener('click', this._rhythmClickHandler); } catch (e) {}
      this._rhythmClickHandler = null;
    }
    if (this._rhythmVideoElements) {
      const { video1, video2 } = this._rhythmVideoElements;
      try { video1 && video1.pause && video1.pause(); } catch (e) {}
      try { video2 && video2.pause && video2.pause(); } catch (e) {}
      this._rhythmVideoElements = null;
    }
  }
};
