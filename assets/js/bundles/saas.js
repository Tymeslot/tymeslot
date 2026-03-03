/**
 * SaaS Bundle
 *
 * Loaded on SaaS marketing pages that don't have route-specific bundles.
 * Connects the LiveSocket with CoreHooks and SaaS-specific hooks (RecaptchaV3).
 */

import { initializeBundle } from "./bundle_utils"
import { RecaptchaV3Hook } from "../hooks/recaptcha_v3_hook"
import { DocsToc } from "../hooks/docs_toc"

const SaasHooks = {
  RecaptchaV3: RecaptchaV3Hook,
  DocsToc
};

initializeBundle("saas", SaasHooks).catch(error => {
  console.error("SaaS bundle initialization failed:", error);
});
