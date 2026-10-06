/**
 * Keyboard activation for elements that act as buttons without being one.
 *
 * An agenda row or card that opens a detail modal is a `<div role="button">`
 * (it holds a real Join link, which a `<button>` may not contain). A native
 * button answers both Enter and Space; a `role="button"` element answers
 * neither on its own, and `phx-keydown` can bind only one key. Marking the
 * element `data-keyboard-click` hands both keys to this listener, which turns
 * them into the element's own click, so its `phx-click` runs exactly as it
 * does for a pointer.
 *
 * Only the marked element itself is handled, never a key pressed inside a
 * link, button or field within it.
 */

export function keyboardClick(event) {
  if (event.key !== "Enter" && event.key !== " ") return;
  if (event.altKey || event.ctrlKey || event.metaKey || event.repeat) return;

  const el = event.target;
  if (!(el instanceof Element) || !el.hasAttribute("data-keyboard-click")) return;

  // Space would otherwise scroll the page.
  event.preventDefault();
  el.click();
}

export function installKeyboardClick(root = document) {
  root.addEventListener("keydown", keyboardClick);
  return () => root.removeEventListener("keydown", keyboardClick);
}
