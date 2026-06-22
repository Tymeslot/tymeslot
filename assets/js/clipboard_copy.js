// Copy text to the clipboard when an element carrying data-clipboard-text is
// clicked. Delegated at the document level so it needs no per-element id and
// works for buttons that repeat on a page (e.g. docs code blocks). Replaces
// inline onclick clipboard handlers, which a nonce-based CSP cannot authorise.
//
// Markup contract:
//   data-clipboard-text="…"   the text to copy when the element is clicked
export function installClipboardCopy() {
  document.addEventListener("click", (event) => {
    const trigger =
      event.target.closest && event.target.closest("[data-clipboard-text]");
    if (!trigger) return;

    const text = trigger.getAttribute("data-clipboard-text");
    if (text && navigator.clipboard) {
      navigator.clipboard.writeText(text).catch(() => {});
    }
  });
}
