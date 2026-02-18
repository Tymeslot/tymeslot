/**
 * Public Booking Bundle
 *
 * Loaded on public booking pages (/:username).
 * Video backgrounds are lazy-loaded only when video elements are detected.
 */

import { initializeBundle } from "./bundle_utils"
import { lazyHook } from "../dynamic_hooks"
import { AutoScrollToSlots } from "../utility_hooks"
import { RecaptchaV3Hook } from "../hooks/recaptcha_v3_hook"

// Define public-specific hooks
const PublicHooks = {
  AutoScrollToSlots,
  RecaptchaV3: RecaptchaV3Hook,
  // Lazy-load video hooks - only load when video elements are mounted
  RhythmVideo: lazyHook("RhythmVideo", () =>
    import("../video_hooks").then(m => m.RhythmVideo)
  ),
  QuillVideo: lazyHook("QuillVideo", () =>
    import("../video_hooks").then(m => m.QuillVideo)
  )
};

// Initialize bundle with shared utility (handles retry logic, errors, telemetry)
initializeBundle("public", PublicHooks).catch(error => {
  console.error("Public bundle initialization failed:", error);
});

export { AutoScrollToSlots };
