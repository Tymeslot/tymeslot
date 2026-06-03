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
 * Measurement protocol:
 * - Every pass measures the SAME thing — ceil(getComputedStyle(main).height +
 *   marginTop + marginBottom) on the booker's outermost flex container (falling
 *   back to documentElement.scrollHeight only when that height is unresolved).
 *   Using one method every time avoids the first-paint "lurch" an earlier version
 *   had, where the iframe jumped from a generous first scrollHeight down to the
 *   smaller computed height.
 * - Growth is posted immediately (so the iframe never flashes an internal
 *   scrollbar mid-expansion); a shrink is posted only once the height has held
 *   steady for one tick, collapsing the transient frames of a step reflow into a
 *   single resize instead of a flicker.
 * - Sub-pixel jitter is suppressed naturally by Math.ceil in measureHeight — the
 *   stored height is always an integer, so equal consecutive measurements are
 *   exact duplicates and are skipped. postMessage is wrapped so a closed/cross-origin
 *   parent can't kill the loop.
 *
 * `setTimeout` (not ResizeObserver/requestAnimationFrame) is used deliberately:
 * Safari and iframe-hidden contexts have well-known issues with the latter.
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
  let lastMeasuredHeight = null;
  let hasPosted = false;

  function findMainElement() {
    return (
      document.getElementsByClassName("main")[0] ||
      document.getElementsByTagName("main")[0] ||
      document.documentElement
    );
  }

  // One consistent measurement every pass — the booker's outermost container
  // height + margins. Falls back to scrollHeight only when the height is
  // unresolved (e.g. computes to `auto`), so the loop never posts NaN.
  function measureHeight() {
    const main = findMainElement();
    const styles = window.getComputedStyle(main);
    const h = parseFloat(styles.height);
    if (Number.isFinite(h)) {
      const mt = parseFloat(styles.marginTop) || 0;
      const mb = parseFloat(styles.marginBottom) || 0;
      return Math.ceil(h + mt + mb);
    }
    return document.documentElement.scrollHeight;
  }

  function postHeight() {
    const height = measureHeight();
    if (!Number.isFinite(height) || height < 1) return;

    const grew = lastPostedHeight === null || height > lastPostedHeight;
    const steady = height === lastMeasuredHeight;
    lastMeasuredHeight = height;

    // Grow immediately (no transient scrollbar); shrink only once the height has
    // settled for a tick (no flicker from a reflow's intermediate frames).
    if (!grew && !steady) return;
    // Skip posting an identical height (steady state with no change).
    if (lastPostedHeight !== null && height === lastPostedHeight) return;

    lastPostedHeight = height;
    const isFirstTime = !hasPosted;
    hasPosted = true;
    try {
      window.parent.postMessage(
        { type: "tymeslot-resize", height: height, isFirstTime: isFirstTime },
        targetOrigin
      );
    } catch (_) {
      // Parent unreachable (closed tab / cross-origin race) — keep looping.
    }
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
