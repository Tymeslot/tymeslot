/**
 * An id for the browser tab the calendar runs in, kept in sessionStorage:
 * a reload of the tab keeps it, and another tab gets its own. The server
 * stores it with each delete, so after a reload only the tab that deleted
 * offers Undo.
 *
 * null when the browser keeps no storage (blocked site data, some private
 * modes); the server then offers no Undo after a reload, which is the safe
 * side to fail on.
 */
export const TAB_ID_KEY = "tymeslot:calendar-tab";

// `storage` defaults to the tab's sessionStorage, read inside the try: with
// site data blocked, merely reading `window.sessionStorage` throws.
export function tabId(storage) {
  try {
    const store = storage ?? globalThis.sessionStorage;
    const kept = store.getItem(TAB_ID_KEY);
    if (kept) return kept;

    const id = newId();
    store.setItem(TAB_ID_KEY, id);
    return id;
  } catch {
    return null;
  }
}

function newId() {
  if (globalThis.crypto?.randomUUID) return globalThis.crypto.randomUUID();
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
}
