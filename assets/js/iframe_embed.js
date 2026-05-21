/**
 * Iframe Embed Detection & Continuous Resize Communication
 *
 * When the scheduling page is loaded inside an iframe (via embed.js),
 * this module:
 * 1. Adds a `data-embedded` attribute to <html> so CSS can adapt
 * 2. Sets `data-embed-mode` ("inline" or "modal") for mode-specific CSS
 * 3. Continuously posts the page's measured height to the parent on a
 *    50ms loop so the parent iframe element can grow AND shrink to match
 *    content as it changes — no dead space at the bottom when the page
 *    shrinks between steps.
 *
 * Measurement protocol (mirrors Cal.com's embed-core approach):
 * - First pass: document.documentElement.scrollHeight (generous; prevents
 *   internal scrollbars before layout settles)
 * - Subsequent passes: ceil(getComputedStyle(main).height + marginTop
 *   + marginBottom) on the booker's outermost flex container. This value
 *   can decrease, which is the whole point.
 * - Diff-checked: same value as the previous post is skipped.
 *
 * `setTimeout` (not ResizeObserver/requestAnimationFrame) is used
 * deliberately: Safari and iframe-hidden contexts have well-known issues
 * with the latter — cal.com chose setTimeout for the same reason.
 */
(function () {
  "use strict";

  const isEmbedded = window.self !== window.top;
  if (!isEmbedded) return;

  document.documentElement.setAttribute("data-embedded", "");

  const params = new URLSearchParams(window.location.search);
  const embedMode = params.get("embed-mode") || "modal";
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
      const paramOrigin = params.get("parent-origin");
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
      "Tymeslot: auto-resize disabled — parent origin could not be determined " +
      "from document.referrer or parent-origin param. Check that the embedding " +
      'page does not set referrerpolicy="no-referrer".'
    );
    return;
  }

  // --- Continuous height measurement loop ---
  const POLL_INTERVAL_MS = 50;
  let lastPostedHeight = null;
  let isFirstPass = true;

  function findMainElement() {
    return (
      document.getElementsByClassName("main")[0] ||
      document.getElementsByTagName("main")[0] ||
      document.documentElement
    );
  }

  function measureHeight() {
    if (isFirstPass) {
      // Generous initial measurement — prevents an internal scrollbar
      // flashing before the first computed-height tick lands.
      return document.documentElement.scrollHeight;
    }
    const main = findMainElement();
    const styles = window.getComputedStyle(main);
    return Math.ceil(
      parseFloat(styles.height) +
      parseFloat(styles.marginTop) +
      parseFloat(styles.marginBottom)
    );
  }

  function postHeight() {
    const height = measureHeight();
    if (!Number.isFinite(height) || height < 1) return;
    if (height === lastPostedHeight) return;

    lastPostedHeight = height;
    window.parent.postMessage(
      { type: "tymeslot-resize", height: height, isFirstTime: isFirstPass },
      targetOrigin
    );
    isFirstPass = false;
  }

  function loop() {
    if (document.hidden) {
      setTimeout(loop, POLL_INTERVAL_MS);
      return;
    }
    postHeight();
    setTimeout(loop, POLL_INTERVAL_MS);
  }

  document.addEventListener("visibilitychange", function () {
    if (!document.hidden) {
      postHeight();
    }
  });

  if (document.body) {
    loop();
  } else {
    document.addEventListener("DOMContentLoaded", loop);
  }
})();
