/**
 * Core Bundle - Shared across all routes
 *
 * This bundle contains the essential LiveView infrastructure
 * and utilities used across all pages. Always loaded.
 */

import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../../vendor/topbar.cjs"

// Core utility hooks used everywhere
import { ConfirmDelete, PageReload } from "../ui_interaction_hooks"
import { Flash, ConnectionStatus, AutoFocus, ScrollReset, CopyOnClick } from "../utility_hooks"
import { ClipboardCopy } from "../clipboard_hook"
import { installAnalytics, installEventBridge, installClickTracking } from "../analytics"

// CSRF token
let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Detect user timezone
function getUserTimezone() {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/Tallinn"
  } catch (e) {
    return "Europe/Tallinn"
  }
}

// Core hooks available on all pages
const CoreHooks = {
  // UI interactions
  ConfirmDelete,
  PageReload,

  // Utilities
  Flash,
  ConnectionStatus,
  AutoFocus,
  ScrollReset,
  CopyOnClick,
  ClipboardCopy
}

// Use /embed-live in cross-site iframes to avoid session cookie dependency
// (mobile browsers block SameSite=Lax cookies in third-party iframe context)
const socketPath = (window.self !== window.top) ? "/embed-live" : "/live"

// Initialize LiveSocket with core hooks
// Route-specific bundles will extend this with additional hooks before connecting
let liveSocket = new LiveSocket(socketPath, Socket, {
  params: {
    _csrf_token: csrfToken,
    timezone: getUserTimezone()
  },
  hooks: CoreHooks
})

// Progress bar
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// Global event handlers
window.addEventListener("phx:reset-form", (e) => {
  const form = document.getElementById(e.detail.id);
  if (form) form.reset();
});

// Inline "Saved" pulse for the admin settings autosave inputs. The flash
// toast still fires top-right, but when the trigger is blur (the user has
// already moved their focus away from the input), an adjacent visual
// confirmation reads much faster than the toast.
window.addEventListener("phx:ts:setting-saved", (e) => {
  const id = `setting-input-${e.detail.key}`;
  const el = document.getElementById(id);
  if (!el) return;

  const pulseClasses = ["ring-4", "ring-turquoise-400", "border-turquoise-500"];
  el.classList.add(...pulseClasses);
  clearTimeout(el.__tymeslot_savedPulseTimer);
  el.__tymeslot_savedPulseTimer = setTimeout(() => {
    el.classList.remove(...pulseClasses);
  }, 1200);
});

window.addEventListener("phx:copy-to-clipboard", (e) => {
  const text = e.detail.text;
  if (navigator.clipboard) {
    navigator.clipboard.writeText(text).then(() => {
      console.log('Copied to clipboard');
    }).catch(err => {
      console.error('Failed to copy:', err);
    });
  }
});

window.addEventListener("tymeslot:clip-copy", (e) => {
  const message = e.detail.message || "Copied to clipboard!";
  const kind = e.detail.kind || "info";

  const container = document.getElementById("flash-group") || document.body;
  const toast = document.createElement("div");

  const isError = kind === "error" || message.toLowerCase().includes("fail") || message.toLowerCase().includes("unavailable");

  toast.className = `fixed top-4 right-4 z-[10060] w-80 sm:w-96 rounded-2xl p-5 shadow-2xl border-2 transition-all duration-500 transform translate-y-4 opacity-0 scale-95 cursor-pointer ${
    isError
      ? "bg-red-50 border-red-100 text-red-900 shadow-red-500/10"
      : "bg-white border-turquoise-100 text-slate-900 shadow-turquoise-500/10"
  }`;

  toast.innerHTML = `
    <div class="relative z-10 flex items-start gap-4">
      <div class="shrink-0 w-10 h-10 rounded-xl flex items-center justify-center shadow-sm border ${
        isError ? "bg-white border-red-100 text-red-500" : "bg-turquoise-50 border-turquoise-100 text-turquoise-600"
      }">
        <svg class="h-6 w-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="${
            isError
              ? "M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
              : "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
          }" />
        </svg>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-bold leading-relaxed">${message}</p>
      </div>
    </div>
  `;

  container.appendChild(toast);

  setTimeout(() => {
    toast.classList.remove("translate-y-4", "opacity-0", "scale-95");
    toast.classList.add("translate-y-0", "opacity-100", "scale-100");
  }, 20);

  const removeToast = () => {
    toast.classList.add("opacity-0", "translate-y-4", "scale-95");
    toast.classList.remove("opacity-100", "translate-y-0", "scale-100");
    setTimeout(() => toast.remove(), 500);
  };

  toast.addEventListener("click", removeToast);
  setTimeout(removeToast, 5000);
});

// Loading state for plain (non-LiveView) form submits that navigate away —
// e.g. the Stripe Connect onboarding POST, which makes two Stripe API calls
// before redirecting, so the page can sit for a second or two. Opt in with
// `data-submit-loading` on the <form>; the button reveals `[data-submit-spinner]`
// and hides `[data-submit-label]`, then disables so it can't be rage-clicked.
document.addEventListener("submit", (e) => {
  const form = e.target;
  if (!form || !form.matches || !form.matches("form[data-submit-loading]")) return;

  const spinner = form.querySelector("[data-submit-spinner]");
  if (spinner) spinner.classList.replace("hidden", "inline-flex");

  const label = form.querySelector("[data-submit-label]");
  if (label) label.classList.add("hidden");

  // Defer disabling: a button disabled synchronously inside its own submit
  // handler can cancel the submission in some browsers. A 0ms timeout lets the
  // navigation start first, then locks the button against further clicks.
  const button = form.querySelector("button[type=submit]");
  if (button) setTimeout(() => { button.disabled = true; }, 0);
}, true);

// OAuth disconnect suppression
document.addEventListener("click", (e) => {
  const link = e.target && e.target.closest
    ? e.target.closest("a[data-tymeslot-suppress-lv-disconnect]")
    : null;

  if (!link) return;
  window.__tymeslot_suppress_lv_disconnect_until = Date.now() + 2500;
}, true);

// Vendor-neutral analytics: facade (no-op unless an analytics script is loaded)
// plus the bridge that forwards server-pushed `ts:analytics` events to it.
installAnalytics();
installEventBridge();
installClickTracking();

// Export for route bundles to extend
window.liveSocket = liveSocket;
window.CoreHooks = CoreHooks;

export { liveSocket, CoreHooks, getUserTimezone };
