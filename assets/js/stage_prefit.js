/**
 * Fits the onboarding stage before the browser first paints it.
 *
 * Loaded as a classic script in the page head, which blocks the first
 * paint: a module script runs only after the page is parsed, and Firefox
 * paints what it has parsed while it waits for a script further down. From
 * here it fits each stage as the parser adds it and its page, through a
 * MutationObserver, whose callbacks run before the next paint, and stops
 * once the page is parsed. Each fitter keeps the stage fitted from then on
 * (a late font or image) until the StageScale hook mounts and takes over
 * (hooks/stage_scale.js).
 */

import { prefitStages } from "./hooks/stage_scale"

const observer = new MutationObserver(() => prefitStages())
observer.observe(document.documentElement, { childList: true, subtree: true })

document.addEventListener(
  "DOMContentLoaded",
  () => {
    observer.disconnect()
    prefitStages()
  },
  { once: true }
)
