/**
 * Reminder custom row: adds a typed reminder when focus leaves the row.
 *
 * The reminder picker's custom row holds a number and a unit, and only joins
 * the list when Add is pressed. A host who types a value and moves on (to
 * another tab of the meeting type form, or to Create in quick add) used to
 * lose it without a word. This hook pushes the row's commit event when focus
 * leaves the row with a value still in it; the owner answers it with
 * `ReminderPickerState.commit_pending/2`, which adds the reminder or shows
 * why it cannot be added.
 *
 * Focus moving within the row (number to unit, unit to Add) is not leaving
 * it, and neither is moving to the Cancel Custom toggle, which exists to
 * discard the value. Safari does not focus a clicked button, so a focusout
 * there carries no `relatedTarget`; the element last pressed stands in for
 * it, which is why the press is recorded before focus moves.
 */

/**
 * Whether focus leaving the row should add what it holds.
 *
 * @param {Element} row the custom row
 * @param {Element|null} next where focus went, or what was pressed
 * @param {string} value the number field's value
 * @returns {boolean}
 */
export function shouldCommit(row, next, value) {
  if ((value || "").trim() === "") return false;
  if (!next) return true;

  return !row.contains(next) && !next.closest("[data-discards-custom-reminder]");
}

export const ReminderCustomRow = {
  mounted() {
    this.pressed = null;

    // The focus change a press causes happens before any timer runs, so the
    // press is forgotten straight after: a later keyboard focusout must not
    // be judged by a click from long before.
    this.onPointerDown = (event) => {
      this.pressed = event.target instanceof Element ? event.target : null;
      setTimeout(() => (this.pressed = null), 0);
    };

    this.onFocusOut = (event) => {
      const next = event.relatedTarget || this.pressed;

      if (!this.el.isConnected) return;

      const value = this.el.querySelector("[name='reminder[value]']")?.value;
      const unit = this.el.querySelector("[name='reminder[unit]']")?.value;

      if (shouldCommit(this.el, next, value)) {
        this.pushEventTo(this.el, this.el.dataset.commitEvent, { reminder: { value, unit } });
      }
    };

    // Capture phase, so the press is known before the focusout it causes.
    document.addEventListener("pointerdown", this.onPointerDown, true);
    this.el.addEventListener("focusout", this.onFocusOut);
  },

  destroyed() {
    document.removeEventListener("pointerdown", this.onPointerDown, true);
  },
};
