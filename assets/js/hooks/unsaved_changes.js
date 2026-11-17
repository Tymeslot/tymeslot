/**
 * Unsaved changes: warns before the tab is closed or reloaded while an
 * autosaving form holds typed text the server has not confirmed as stored.
 *
 * An autosaving form sends a field when it loses focus, and every way out of
 * the page inside the app (a link, a sidebar entry) takes the focus first.
 * Closing or reloading the tab does not, so that is what this guards.
 *
 * The form is dirty from the first keystroke until the server pushes
 * `autosave:clean` for it (`TymeslotWeb.Components.Dashboard.Autosave.clean/2`):
 * after a save, or when the value turned out to be unchanged. A field the
 * server refused stays dirty, so its text is not lost without a warning.
 *
 * Typing again before the server answers keeps the form dirty: the answer
 * only covers what had been sent, which is everything typed up to the last
 * time a field lost focus or the form was submitted.
 */
export const UnsavedChanges = {
  mounted() {
    this.edits = 0;
    this.sent = 0;
    this.dirty = false;

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

    this.el.addEventListener("input", this.onInput);
    this.el.addEventListener("focusout", this.onSend);
    this.el.addEventListener("submit", this.onSend);
    window.addEventListener("beforeunload", this.onBeforeUnload);

    this.handleEvent("autosave:clean", ({ id }) => {
      if (id === this.el.id && this.sent === this.edits) this.dirty = false;
    });
  },

  destroyed() {
    window.removeEventListener("beforeunload", this.onBeforeUnload);
  },
};
