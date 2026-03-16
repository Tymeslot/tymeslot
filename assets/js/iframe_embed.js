/**
 * Iframe Embed Detection & Resize Communication
 *
 * When the scheduling page is loaded inside an iframe (via embed.js),
 * this module:
 * 1. Adds a `data-embedded` attribute to <html> so CSS can adapt
 * 2. Uses ResizeObserver to post height changes to the parent window
 */

(function () {
  "use strict";

  const isEmbedded = window.self !== window.top;
  if (!isEmbedded) return;

  // Signal to CSS that we're in an iframe
  document.documentElement.setAttribute("data-embedded", "");

  // Post height to parent so embed.js can resize the iframe.
  // Use body.offsetHeight (actual content) instead of scrollHeight
  // because scrollHeight = max(viewport, content) and never shrinks
  // below the iframe's initial viewport size.
  //
  // Derive the allowed parent origin. Prefer document.referrer (browser-
  // provided, hard to spoof). Fall back to the parent-origin URL param
  // that embed.js passes explicitly — this covers embedding pages that
  // strip the Referrer header (e.g. referrerpolicy="no-referrer").
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
      const params = new URLSearchParams(window.location.search);
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
    // Auto-resize is disabled when the embedding page strips the Referrer header
    // and embed.js did not pass a parent-origin param. The widget will still
    // render correctly but the iframe height will not auto-adjust to content.
    console.warn(
      'Tymeslot: auto-resize disabled — parent origin could not be determined ' +
      'from document.referrer or parent-origin param. Check that the embedding ' +
      'page does not set referrerpolicy="no-referrer".'
    );
    return;
  }

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
