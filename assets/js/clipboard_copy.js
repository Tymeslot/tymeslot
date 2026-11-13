// Copy text to the clipboard when an element carrying data-clipboard-text is
// clicked. Delegated at the document level so it needs no per-element id and
// works for buttons that repeat on a page (e.g. docs code blocks). Replaces
// inline onclick clipboard handlers, which a nonce-based CSP cannot authorise.
//
// Markup contract:
//   data-clipboard-text="…"      the text to copy when the element is clicked
//   data-clipboard-copied="…"    optional: the label shown on the element for a
//                                moment after a successful copy
//   data-clipboard-success="…"   optional: the toast on success
//   data-clipboard-failure="…"   optional: the toast when the copy fails or
//                                the clipboard is unavailable (an insecure
//                                context has no navigator.clipboard)
//
// Feedback goes through the `tymeslot:clip-copy` toast that every other copy
// action uses (listener in bundles/core.js).

const LABEL_MS = 2000
const SUCCESS = "Copied to clipboard!"
const FAILURE = "Could not copy to clipboard"

function announce(message, kind) {
  window.dispatchEvent(new CustomEvent("tymeslot:clip-copy", { detail: { message, kind } }))
}

function showCopied(trigger) {
  const copied = trigger.getAttribute("data-clipboard-copied")
  if (!copied) return

  if (trigger._clipboardTimer) {
    clearTimeout(trigger._clipboardTimer)
  } else {
    trigger._clipboardLabel = trigger.textContent
  }
  trigger.textContent = copied
  trigger._clipboardTimer = setTimeout(() => {
    trigger.textContent = trigger._clipboardLabel
    trigger._clipboardTimer = null
  }, LABEL_MS)
}

export function installClipboardCopy() {
  document.addEventListener("click", (event) => {
    const trigger =
      event.target.closest && event.target.closest("[data-clipboard-text]");
    if (!trigger) return;

    const text = trigger.getAttribute("data-clipboard-text");
    if (!text) return;

    const failure = () =>
      announce(trigger.getAttribute("data-clipboard-failure") || FAILURE, "error")

    if (!navigator.clipboard) {
      failure()
      return
    }

    navigator.clipboard.writeText(text).then(
      () => {
        showCopied(trigger)
        announce(trigger.getAttribute("data-clipboard-success") || SUCCESS, "info")
      },
      failure
    )
  });
}
