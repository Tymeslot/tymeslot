/**
 * Auth Bundle
 *
 * Loaded on authentication pages (/auth/*).
 * AuthVideo is lazy-loaded only when video elements are detected.
 */

import { initializeBundle } from "./bundle_utils"
import { lazyHook } from "../dynamic_hooks"
import { PasswordToggle } from "../password_toggle"
import { AuthAutoFocus } from "../utility_hooks"

// Define auth-specific hooks
// (RecaptchaV3 is already registered in CoreHooks and inherited via initializeBundle)
const AuthHooks = {
  PasswordToggle,
  AuthAutoFocus,
  // Lazy-load auth video - only load when video element is mounted
  AuthVideo: lazyHook("AuthVideo", () =>
    import("../video_hooks").then(m => m.AuthVideo)
  )
};

// Initialize bundle with shared utility (handles retry logic, errors, telemetry)
initializeBundle("auth", AuthHooks).catch(error => {
  console.error("Auth bundle initialization failed:", error);
});

export { PasswordToggle };
