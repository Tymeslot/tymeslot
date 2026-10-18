/**
 * The quick-create popover, for the CalendarCanvas hook (mixed into it).
 *
 * Opens on the draft the draft mixin dropped (calendar_canvas/draft.js),
 * as a non-modal dialog appended to <body> so a grid redraw never takes
 * the field's caret with it. Typing re-reads the field (calendar/parse.js)
 * and moves the draft at once; the chips under it are real controls whose
 * edits become the draft's new base (calendar/draft.js). When the draft's
 * day leaves the visible period the grid follows it after a short pause, so
 * a half-typed date does not send it wandering.
 *
 * Enter or Save pushes `calendar:create` with the draft's fields (the
 * server re-validates every one). The popover stays open, its Save button
 * reading "Saving…", until the reply: accepted, it closes and the draft is
 * drawn as saving until the server's payload takes over; refused, it shows
 * the server's message (anchored to the refused chip when the reply names
 * a field, on its own when it does not) and stays open. "Save and invite"
 * replaces Save when the text names guests, because saving emails them.
 * More options pushes `calendar:more_options` and, once the panel opened,
 * hands the draft to it. Escape, or a press outside, cancels; Escape
 * returns focus to where it was. Tab cycles inside the popover. A draft
 * being saved cannot be cancelled: the server is already writing it.
 *
 * C anywhere on the page but a text field or a dialog, and the toolbar's
 * Create (which dispatches `calendar:quick-create` on the canvas), open
 * quick create at the next free slot (calendar/draft.js `nextSlot`).
 */
import { applyChip, applyText, draftFromRange, nextSlot, toPayload } from "../../calendar/draft.js";
import { placePopover } from "../../calendar/popover.js";
import { renderQuickBody, renderQuickCreate } from "../../calendar/quick_create.js";
import { MINUTES_PER_DAY, isoFromDay, periodDays } from "../../calendar/time.js";
import { newDraftId } from "./draft.js";
import { MODALS, TYPING } from "./keys.js";

const ESTIMATE = { width: 340, height: 320 };
const FOLLOW_MS = 400;
// How long a push may go unanswered before the popover unlocks.
const REPLY_MS = 15000;
const FOCUSABLE = 'input:not([tabindex="-1"]), select, button:not([disabled]):not([hidden])';

const viewport = () => ({ width: window.innerWidth, height: window.innerHeight });
// Draft ids are ours (calendar_canvas/draft.js: letters and digits), safe in a selector.
const draftSelector = (id) => `[data-draft-id="draft-${id}"]`;

export const CreateMixin = {
  mountCreate() {
    this.quick = null;
    this.followTimer = null;
    this.pushTimer = null;
    this.lostPush = null;
    this.quickOutside = (e) => {
      if (!this.quick || this.quick.element.contains(e.target) || e.target.closest?.("[data-draft-id]")) return;
      this.cancelQuickCreate({ restoreFocus: false });
    };
    this.quickScroll = () => this.placeQuickCreate();
    this.createKey = (e) => {
      if ((e.key !== "c" && e.key !== "C") || e.repeat || e.ctrlKey || e.metaKey || e.altKey || e.isComposing || e.defaultPrevented) return;
      if (this.drag || this.createDrag || this.moving) return;
      const target = e.target;
      if (target?.isContentEditable || target?.closest?.(`${TYPING}, [role="dialog"], dialog`) || document.querySelector(MODALS)) return;
      e.preventDefault();
      this.quickCreateNext();
    };
    this.quickCreateEvent = () => this.quickCreateNext();
    this.el.addEventListener("scroll", this.quickScroll, true);
    this.el.addEventListener("calendar:quick-create", this.quickCreateEvent);
    document.addEventListener("keydown", this.createKey);
  },

  destroyCreate() {
    this.clearPush();
    this.el.removeEventListener("scroll", this.quickScroll, true);
    this.el.removeEventListener("calendar:quick-create", this.quickCreateEvent);
    document.removeEventListener("keydown", this.createKey);
    this.closeQuickCreate();
  },

  // Quick create at the next free slot of the visible days, or of tomorrow
  // late in the evening; the grid follows when that day is not in view.
  quickCreateNext() {
    if (!this.settings || !this.clock) return;
    if (this.quick) {
      this.quickField().focus({ preventScroll: true });
      return;
    }
    const days = periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
    const range = nextSlot(this.nowMinute(), days, [...this.cache.events.values()], undefined, this.currentScale().firstMinute);
    // The preview (rendered by LiveView) would otherwise stay beside the draft.
    if (document.getElementById("calendar-preview")) this.pushEventTo(this.el, "calendar:close_preview", { refocus: "false" });
    this.startDraft(draftFromRange(newDraftId(), range, this.defaultCalendar()));
    this.followDraft(0);
  },

  quickState() {
    return { draft: this.draft, strings: this.strings, timeFormat: this.settings.time_format, calendars: this.settings.calendars || [] };
  },

  parseOptions() {
    return { today: isoFromDay(Math.floor(this.nowMinute() / MINUTES_PER_DAY)), calendars: this.settings.calendars || [] };
  },

  openQuickCreate() {
    if (!this.draft) return;
    if (!this.quick) {
      const holder = document.createElement("div");
      holder.innerHTML = renderQuickCreate(this.quickState());
      const element = holder.firstElementChild;
      const active = document.activeElement;
      this.quick = { element, returnTo: active && active !== document.body ? active : null };
      element.addEventListener("input", (e) => this.quickInput(e));
      element.addEventListener("change", (e) => this.quickChange(e));
      element.addEventListener("click", (e) => this.quickClick(e));
      element.addEventListener("keydown", (e) => this.quickKey(e));
      document.body.appendChild(element);
      document.addEventListener("pointerdown", this.quickOutside);
    }
    this.placeQuickCreate();
    this.quickField().focus({ preventScroll: true });
  },

  quickField() {
    return this.quick.element.querySelector("#calendar-qc-field");
  },

  // Forgets the popover; the draft is the caller's business.
  closeQuickCreate() {
    clearTimeout(this.followTimer);
    this.followTimer = null;
    document.removeEventListener("pointerdown", this.quickOutside);
    this.quick?.element.remove();
    this.quick = null;
  },

  cancelQuickCreate({ restoreFocus = true } = {}) {
    if (!this.quick || this.draft?.status === "saving") return;
    const returnTo = this.quick.returnTo;
    this.closeQuickCreate();
    this.discardDraft();
    if (restoreFocus) this.restoreQuickFocus(returnTo);
  },

  restoreQuickFocus(returnTo) {
    if (returnTo?.isConnected) return returnTo.focus({ preventScroll: true });
    const block = this.el.querySelector('.cal-col .cal-ev[data-event-id][tabindex="0"]');
    if (block) return block.focus({ preventScroll: true });
    // No events: the grid itself takes focus, so it never drops to the page.
    if (!this.el.hasAttribute("tabindex")) this.el.tabIndex = -1;
    return this.el.focus({ preventScroll: true });
  },

  // A new draft state: redraw the grid, then the popover's body beside it.
  updateDraft(draft) {
    this.draft = draft;
    this.render();
    this.refreshQuick();
    this.followDraft();
  },

  quickInput(e) {
    if (e.target.id !== "calendar-qc-field" || this.draft?.status !== "editing") return;
    this.updateDraft(applyText(this.draft, e.target.value, this.parseOptions()));
  },

  quickChange(e) {
    const chip = e.target.dataset?.qcInput;
    if (!chip || this.draft?.status !== "editing") return;
    this.updateDraft(applyChip(this.draft, chip, e.target.value));
  },

  quickClick(e) {
    const target = e.target.closest("button");
    if (!target || !this.draft) return;
    if (target.dataset.qcPick) return this.openPicker(target);
    if (this.draft.status !== "editing") return undefined;
    if (target.hasAttribute("data-qc-allday")) return this.updateDraft(applyChip(this.draft, "allDay", !this.draft.allDay));
    if (target.dataset.qcFree) return this.updateDraft(applyChip(this.draft, "free", target.dataset.qcFree === "true"));
    if (target.hasAttribute("data-qc-save")) return this.saveQuickCreate();
    if (target.hasAttribute("data-qc-more")) return this.moreOptions();
    return undefined;
  },

  quickKey(e) {
    if (e.key === "Escape") {
      e.preventDefault();
      // Nothing behind the popover (the preview, the grid's own keys) sees it.
      e.stopPropagation();
      return this.cancelQuickCreate();
    }
    if (e.key === "Enter" && e.target.id === "calendar-qc-field" && !e.isComposing) {
      e.preventDefault();
      return this.saveQuickCreate();
    }
    if (e.key === "Tab") return this.trapTab(e);
    // Keys typed here are the field's, not the page's shortcuts.
    e.stopPropagation();
    return undefined;
  },

  trapTab(e) {
    const items = [...this.quick.element.querySelectorAll(FOCUSABLE)];
    if (!items.length) return;
    const first = items[0];
    const last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  },

  // The date and time chips open the browser's own picker; where it has no
  // showPicker (or refuses), the input itself takes the chip's place.
  openPicker(button) {
    const input = button.parentElement.querySelector("[data-qc-input]");
    try {
      if (typeof input.showPicker !== "function") throw new Error("no picker");
      input.showPicker();
    } catch (_error) {
      (this.quick.open ||= new Set()).add(button.dataset.qcPick);
      this.showInput(button, input);
      input.focus();
    }
  },

  showInput(button, input) {
    button.hidden = true;
    input.classList.add("is-open");
    input.removeAttribute("aria-hidden");
    input.tabIndex = 0;
  },

  // Re-renders everything under the field, keeping focus on the same control.
  refreshQuick() {
    if (!this.quick || !this.draft) return;
    const key = document.activeElement?.closest?.("[data-qc-key]")?.dataset.qcKey;
    this.quick.element.querySelector("[data-qc-body]").innerHTML = renderQuickBody(this.quickState());
    const field = this.quickField();
    field.readOnly = this.draft.status !== "editing";
    if (this.draft.error?.field === "title") {
      field.setAttribute("aria-invalid", "true");
      field.setAttribute("aria-describedby", "calendar-qc-error calendar-qc-hint");
    } else {
      field.removeAttribute("aria-invalid");
      field.setAttribute("aria-describedby", "calendar-qc-hint");
    }
    // A native picker shown in a chip's place stays shown through the redraw.
    for (const chip of this.quick.open || []) {
      const wrap = this.quick.element.querySelector(`[data-qc-pick="${chip}"]`)?.parentElement;
      if (wrap) this.showInput(wrap.querySelector("[data-qc-pick]"), wrap.querySelector("[data-qc-input]"));
    }
    if (key) this.quick.element.querySelector(`[data-qc-key="${key}"]`)?.focus({ preventScroll: true });
    this.placeQuickCreate();
  },

  // Beside the draft, never over it (calendar/popover.js); in the middle of
  // the grid while the draft is not drawn (its days still loading).
  placeQuickCreate() {
    if (!this.quick || !this.draft) return;
    const { element } = this.quick;
    const block = this.el.querySelector(draftSelector(this.draft.id));
    let anchor;
    if (block) {
      anchor = block.getBoundingClientRect();
    } else {
      const box = this.el.getBoundingClientRect();
      const x = box.left + box.width / 2 - ESTIMATE.width / 2;
      anchor = { left: x, right: x, top: box.top + 80, bottom: box.top + 80 };
    }
    const size = { width: element.offsetWidth || ESTIMATE.width, height: element.offsetHeight || ESTIMATE.height };
    const { left, top, maxHeight } = placePopover(anchor, size, viewport());
    element.style.left = `${Math.round(left)}px`;
    element.style.top = `${Math.round(top)}px`;
    element.style.maxHeight = maxHeight ? `${Math.round(maxHeight)}px` : "";
  },

  // After a pause in typing (`delay`), brings the draft into view: the grid moves to
  // its day when that is not visible, else the draft scrolls into sight.
  followDraft(delay = FOLLOW_MS) {
    clearTimeout(this.followTimer);
    this.followTimer = setTimeout(() => {
      this.followTimer = null;
      if (!this.draft) return;
      const iso = isoFromDay(Math.floor(this.draft.start / MINUTES_PER_DAY));
      const days = periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
      if (!days.includes(iso)) {
        this.navigate({ view: this.view, date: iso });
        this.pushEventTo(this.el, "calendar:goto", { view: this.view, date: iso });
        return;
      }
      this.el.querySelector(draftSelector(this.draft.id))?.scrollIntoView?.({ block: "nearest" });
    }, delay);
  },

  // Pushes `event` and settles once: on the server's reply, or as `lost`
  // when the push is rejected, unanswered for REPLY_MS or the socket
  // reconnected (the hook's pushes swallow a dead connection, so without
  // this the popover would wait for ever).
  pushGuarded(event, params, onReply, onLost) {
    this.clearPush();
    let settled = false;
    const settle = (callback) => (arg) => {
      if (settled) return;
      settled = true;
      this.clearPush();
      callback(arg);
    };
    const lost = settle(onLost);
    this.lostPush = lost;
    this.pushTimer = setTimeout(lost, REPLY_MS);
    const pushed = this.pushEventTo(this.el, event, params, settle(onReply));
    pushed?.catch?.(lost);
  },

  clearPush() {
    clearTimeout(this.pushTimer);
    this.pushTimer = null;
    this.lostPush = null;
  },

  // A push in flight whose reply will not come (called on reconnect).
  abandonPush() {
    this.lostPush?.();
  },

  saveQuickCreate() {
    if (this.draft?.status !== "editing") return;
    this.updateDraft({ ...this.draft, status: "saving", error: null });
    const { id } = this.draft;
    this.pushGuarded("calendar:create", toPayload(this.draft), (reply) => this.createReplied(id, reply), () => this.createReplied(id, { accepted: false, field: null }));
  },

  createReplied(id, reply) {
    if (this.draft?.id !== id) return;
    if (reply?.accepted) {
      const returnTo = this.quick?.returnTo;
      this.closeQuickCreate();
      this.handOver("created");
      this.restoreQuickFocus(returnTo);
      return;
    }
    this.reopenWithError(reply?.field ?? null, reply?.error);
  },

  // Back to editing with the server's message (or the generic one). A refusal
  // may name no field (a rate limit): the message then stands alone.
  reopenWithError(field, message) {
    this.draft = { ...this.draft, status: "editing", error: { field, message: message || this.strings.create_refused } };
    this.render();
    this.refreshQuick();
    this.quickField()?.focus({ preventScroll: true });
  },

  moreOptions() {
    if (this.draft?.status !== "editing") return;
    this.updateDraft({ ...this.draft, status: "opening", error: null });
    const { id } = this.draft;
    const unlock = () => {
      if (this.draft?.id === id) this.reopenWithError(null, null);
    };
    this.pushGuarded(
      "calendar:more_options",
      toPayload(this.draft),
      (reply) => {
        if (this.draft?.id !== id) return;
        if (!reply?.opened) {
          this.draft = { ...this.draft, status: "editing" };
          this.render();
          this.refreshQuick();
          return;
        }
        this.closeQuickCreate();
        // The panel takes focus; the draft stays drawn until its payload.
        this.handOver("panel");
      },
      unlock,
    );
  },
};
