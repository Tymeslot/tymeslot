/**
 * SaaS Bundle
 *
 * Loaded on SaaS marketing pages that don't have route-specific bundles.
 * Simply connects the LiveSocket with CoreHooks (no additional hooks needed).
 */

import { initializeBundle } from "./bundle_utils"

// Initialize with CoreHooks only (no additional hooks for SaaS marketing pages)
initializeBundle("saas", {}).catch(error => {
  console.error("SaaS bundle initialization failed:", error);
});
