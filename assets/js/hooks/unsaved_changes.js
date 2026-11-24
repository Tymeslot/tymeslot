/**
 * Unsaved changes: guards typed text the server has not confirmed as stored.
 *
 * The element is dirty from the first keystroke until the server pushes
 * `autosave:clean` for it (`TymeslotWeb.Components.Dashboard.Autosave.clean/2`):
 * after a save, or when the value turned out to be unchanged. A field the
 * server refused stays dirty, so its text is not lost without a warning.
 * Typing again before the server answers keeps it dirty: the answer only
 * covers what had been sent.
 *
 * While dirty, closing or reloading the tab asks first. Beyond that, the
 * element is one of two kinds:
 *
 *   * An autosaving form sends a field when it loses focus, and every way
 *     out of the page inside the app (a link, a sidebar entry) takes the
 *     focus first, so the tab is all there is to guard.
 *
 *   * An explicit-submit editor (`data-leave-event`) sends only on submit,
 *     so following a LiveView link elsewhere would drop what was typed. The
 *     click is held and the named event pushed to `data-leave-target` (a
 *     `@myself`, or this element's own component when absent). The server
 *     saves or asks, and pushes `unsaved:proceed` once the way is clear,
 *     which follows the held link.
 *
 * Either way, leaving a field counts as sending it: a `phx-change` the
 * editor debounces is dispatched on blur, so the server holds the draft
 * from then on, and a save it starts itself (on leaving, or on another
 * control of the editor) covers what was typed. Leaving a field never makes
 * the element clean on its own; only the server's `autosave:clean` does.
 */

// Set while a held link is followed, so that no guard holds it again.
let proceeding = false;

export const UnsavedChanges = {
  mounted() {
    this.edits = 0;
    this.sent = 0;
    this.dirty = false;
    this.held = null;

    const leaveEvent = this.el.dataset.leaveEvent;

    this.onInput = () => {
      this.edits += 1;
      this.dirty = true;
    };
    this.onSend = () => {
      this.sent = this.edits;
    };
    this.onBeforeUnload = (event) => {
      if (!this.dirty) return;
      event.preventDefault();
      // Older browsers show the prompt only when returnValue is set.
      event.returnValue = "";
    };
    this.onClick = (event) => {
      const link = leavingLink(event, this.el);
      if (!link || !this.dirty || proceeding || event.defaultPrevented) return;

      // LiveView follows links from a bubbling listener on window, so
      // stopping the click here keeps the page where it is.
      event.preventDefault();
      event.stopPropagation();
      this.held = link;
      this.pushEventTo(this.el.dataset.leaveTarget || this.el, leaveEvent, {});
    };

    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("submit", this.onSend);
    window.addEventListener("beforeunload", this.onBeforeUnload);

    this.el.addEventListener("focusout", this.onSend);
    if (leaveEvent) document.addEventListener("click", this.onClick, true);

    this.handleEvent("autosave:clean", ({ id }) => {
      if (id === this.el.id && this.sent === this.edits) this.dirty = false;
    });

    this.handleEvent("unsaved:proceed", () => {
      const link = this.held;
      this.held = null;
      if (!link || !link.isConnected) return;

      proceeding = true;
      try {
        link.click();
      } finally {
        proceeding = false;
      }
    });
  },

  destroyed() {
    window.removeEventListener("beforeunload", this.onBeforeUnload);
    document.removeEventListener("click", this.onClick, true);
  },
};

// The LiveView link a click would follow away from `el`, or null: a click
// opening a new tab, or a link inside the editor itself, leaves nothing behind.
function leavingLink(event, el) {
  const link = event.target instanceof Element && event.target.closest("a[data-phx-link]");
  if (!link || el.contains(link)) return null;
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
    return null;
  }
  if (link.target && link.target !== "_self") return null;
  return link;
}
