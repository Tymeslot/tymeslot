/**
 * Public Booking Bundle
 *
 * Loaded on public booking pages (/:username).
 * Video backgrounds are lazy-loaded only when video elements are detected.
 */

import { initializeBundle } from "./bundle_utils"
import { lazyHook } from "../dynamic_hooks"
import { AutoScrollToSlots } from "../utility_hooks"
import { PaymentRedirectOpenTab } from "../hooks/payment_redirect_open_tab"

// Define public-specific hooks
// (RecaptchaV3 is already registered in CoreHooks and inherited via initializeBundle)
const PublicHooks = {
  AutoScrollToSlots,
  PaymentRedirectOpenTab,
  // Lazy-load video hooks - only load when video elements are mounted
  RhythmVideo: lazyHook("RhythmVideo", () =>
    import("../video_hooks").then(m => m.RhythmVideo)
  ),
  QuillVideo: lazyHook("QuillVideo", () =>
    import("../video_hooks").then(m => m.QuillVideo)
  ),
  // Only rendered alongside a video background, so it lazy-loads with them.
  BackgroundMotionToggle: lazyHook("BackgroundMotionToggle", () =>
    import("../video_hooks").then(m => m.BackgroundMotionToggle)
  )
};

// Initialize bundle with shared utility (handles retry logic, errors, telemetry)
initializeBundle("public", PublicHooks).catch(error => {
  console.error("Public bundle initialization failed:", error);
});

export { AutoScrollToSlots };
