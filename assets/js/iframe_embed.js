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
  // Derive the allowed parent origin from document.referrer.
  // When the referrer is unavailable (privacy settings, noreferrer, etc.)
  // we refuse to post rather than broadcasting to "*".
  const targetOrigin = document.referrer
    ? new URL(document.referrer).origin
    : null;

  if (!targetOrigin) return;

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
