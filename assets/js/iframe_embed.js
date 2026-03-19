/**
 * Iframe Embed Detection & Resize Communication
 *
 * When the scheduling page is loaded inside an iframe (via embed.js),
 * this module:
 * 1. Adds a `data-embedded` attribute to <html> so CSS can adapt
 * 2. Sets `data-embed-mode` ("inline" or "modal") for mode-specific CSS
 * 3. For inline embeds: posts the theme-preferred height (from
 *    data-preferred-embed-height on <html>) so embed.js can size the
 *    iframe instead of using the generic 400px default
 * 4. For modal embeds: uses ResizeObserver to post height changes to the
 *    parent window so the modal can size to content
 */

(function () {
  "use strict";

  const isEmbedded = window.self !== window.top;
  if (!isEmbedded) return;

  // Signal to CSS that we're in an iframe
  document.documentElement.setAttribute("data-embedded", "");

  // Read embed mode from URL params (set by embed.js)
  const params = new URLSearchParams(window.location.search);
  const embedMode = params.get('embed-mode') || 'modal';
  document.documentElement.setAttribute("data-embed-mode", embedMode);

  // --- Derive the allowed parent origin ---
  // Prefer document.referrer (browser-provided, hard to spoof). Fall back
  // to the parent-origin URL param that embed.js passes explicitly — this
  // covers embedding pages that strip the Referrer header.
  // We never broadcast to "*".
  let targetOrigin = null;
  try {
    if (document.referrer) {
      const parsed = new URL(document.referrer);
      if (parsed.origin !== "null") targetOrigin = parsed.origin;
    }
  } catch (_) {
    // Malformed referrer — fall through to param check
  }

  if (!targetOrigin) {
    try {
      const paramOrigin = params.get('parent-origin');
      if (paramOrigin) {
        const parsed = new URL(paramOrigin);
        if (parsed.origin !== "null" && /^https?:$/.test(parsed.protocol)) {
          targetOrigin = parsed.origin;
        }
      }
    } catch (_) {
      // Malformed param — fall through to the warning below
    }
  }

  if (!targetOrigin) {
    console.warn(
      'Tymeslot: auto-resize disabled — parent origin could not be determined ' +
      'from document.referrer or parent-origin param. Check that the embedding ' +
      'page does not set referrerpolicy="no-referrer".'
    );
    return;
  }

  // --- Inline mode: post theme-preferred height, then done ---
  // The theme declares its ideal embed height via data-preferred-embed-height
  // on <html>. Post it once so embed.js can size the iframe instead of using
  // the generic 400px default.
  if (embedMode === 'inline') {
    const preferred = parseInt(
      document.documentElement.getAttribute("data-preferred-embed-height"), 10
    );
    if (preferred > 0) {
      window.parent.postMessage(
        { type: "tymeslot-preferred-height", height: preferred },
        targetOrigin
      );
    }
    return;
  }

  // --- Modal mode: post content height so embed.js can size the wrapper ---
  // Use body.offsetHeight (actual content) instead of scrollHeight
  // because scrollHeight = max(viewport, content) and never shrinks
  // below the iframe's initial viewport size.
  let lastPostedHeight = null;
  let rafPending = false;

  function postHeight() {
    const height = document.body.offsetHeight;
    if (height === lastPostedHeight || height < 1) return;
    lastPostedHeight = height;
    window.parent.postMessage(
      { type: "tymeslot-resize", height: height },
      targetOrigin
    );
  }

  // Observe body size changes and post updated height (debounced via rAF)
  if (typeof ResizeObserver !== "undefined") {
    const observer = new ResizeObserver(function () {
      if (!rafPending) {
        rafPending = true;
        requestAnimationFrame(function () {
          rafPending = false;
          postHeight();
        });
      }
    });

    if (document.body) {
      observer.observe(document.body);
    } else {
      document.addEventListener("DOMContentLoaded", function () {
        observer.observe(document.body);
      });
    }
  }

  // Also post on load and after LiveView patches
  window.addEventListener("load", postHeight);
  window.addEventListener("phx:page-loading-stop", postHeight);
})();
