/**
 * Keyboard helpers for the calendar hook's shortcuts.
 *
 * TYPING: where a key is typing, not a shortcut. MODALS: the overlays that
 * take the keyboard while open (the series and delete prompts, the command
 * bar while open, the shortcut help, the import modal and any open core
 * modal, which shows itself with an inline display: flex), so every
 * single-key shortcut, and Ctrl Z, does nothing behind them.
 *
 * `plainKeyAllowed(e, hook)` is the guard every single-key shortcut passes:
 * no modifier, no held key, no IME composition, nothing already handled; the
 * grid has its settings and no drag, move or quick create is live; the key
 * was not typed in a field, a dialog or behind a modal. `isCommandKey`,
 * `digitOf` and `isMac` serve the command bar, the set keys and the labels
 * that name Ctrl or Cmd.
 */
export const TYPING = 'input, textarea, select, [contenteditable=""], [contenteditable="true"]';
// An open core modal: core_components/modal.ex shows its overlay with an inline display: flex.
export const CORE_MODAL_OPEN = '.modal-overlay[style*="display: flex"]';
export const MODALS = `#calendar-series-scope, #calendar-delete-confirm, #calendar-command[data-open], #calendar-shortcuts, #calendar-import, ${CORE_MODAL_OPEN}`;

export function plainKeyAllowed(e, hook) {
  if (e.repeat || e.ctrlKey || e.metaKey || e.altKey || e.isComposing || e.defaultPrevented) return false;
  if (!hook.settings || hook.drag || hook.createDrag || hook.moving || hook.quick) return false;
  const target = e.target;
  if (target?.isContentEditable || target?.closest?.(`${TYPING}, [role="dialog"], dialog`)) return false;
  return !document.querySelector(MODALS);
}

// Ctrl K, or Cmd K on a Mac, with nothing else held.
export function isCommandKey(e) {
  return !!(e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && e.key?.toLowerCase() === "k";
}

// The digit a key types (number row or keypad), or null. Shift is allowed because
// the AZERTY number row types its digits with it; the key itself says it is a digit.
export function digitOf(e) {
  if (!/^[0-9]$/.test(e.key ?? "")) return null;
  return Number(e.key);
}

// Whether shortcuts read Cmd rather than Ctrl, for labels only.
export function isMac(nav) {
  const platform = nav?.userAgentData?.platform || nav?.platform || "";
  return /mac|iphone|ipad|ipod/i.test(platform);
}
