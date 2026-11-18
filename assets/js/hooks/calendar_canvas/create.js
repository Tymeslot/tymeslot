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
 * a field, on its own when it does not) and stays open. A save whose reply
 * is lost (the push rejected, unanswered in time, or the socket reconnected)
 * may still have been written, so Save is never offered again: the draft
 * goes and a notice asks the organiser to check their calendar, where the
 * reload shows the event if it landed. "Save and invite"
 * replaces Save when the text names guests, because saving emails them.
 * The kind switch above the field turns the draft into an opening for a
 * meeting type (calendar_canvas/opening.js), which hides the field and saves
 * through `calendar:open_booking` instead.
 * More options pushes `calendar:more_options` and, once the panel opened,
 * hands the draft to it; when the panel first asks about a draft of its own
 * with uninvited guests, `calendar:more-options-again` chooses it again
 * after Discard. Escape, or a press outside, cancels; Escape
 * returns focus to where it was. Tab cycles inside the popover. A draft
 * being saved cannot be cancelled: the server is already writing it.
 *
 * C anywhere on the page but a text field or a dialog, and the toolbar's
 * Create (which dispatches `calendar:quick-create` on the canvas), open
 * quick create at the next free slot (calendar/draft.js `nextSlot`).
 */
import { applyChip, applyText, draftFromRange, nextSlot, toPayload } from "../../calendar/draft.js";
import { applyPlacement, placeOverlay, releaseSheet, sheetCovers } from "../../calendar/sheet.js";
import { renderQuickBody, renderQuickCreate, renderQuickHead } from "../../calendar/quick_create.js";
import { MINUTES_PER_DAY, isTimeGrid, isoFromDay, periodDays } from "../../calendar/time.js";
import { isCoarse } from "../../calendar/viewport.js";
import { newDraftId } from "./draft.js";
import { MODALS, TYPING } from "./keys.js";

const ESTIMATE = { width: 340, height: 320 };
const FOLLOW_MS = 400;
// How long a push may go unanswered before the popover unlocks.
const REPLY_MS = 15000;
// How long the notice about an unconfirmed save stays, as the server's toast does.
const NOTICE_MS = 10000;
const FOCUSABLE = 'input:not([tabindex="-1"]):not([hidden]), select, button:not([disabled]):not([hidden])';

const viewport = () => ({ width: window.innerWidth, height: window.innerHeight });
// Draft ids are ours (calendar_canvas/draft.js: letters and digits), safe in a selector.
const draftSelector = (id) => `[data-draft-id="draft-${id}"]`;

export const CreateMixin = {
  mountCreate() {
    this.quick = null;
    this.followTimer = null;
    this.pushTimer = null;
    this.lostPush = null;
    this.notice = null;
    this.noticeTimer = null;
    this.quickOutside = (e) => {
      // A press on a sheet's scrim is left to the scrim's click, which
      // cancels; the tap then never reaches the grid under it.
      if (e.target.closest?.("[data-sheet-scrim]")) return;
      // A press in a dialog the popover waits on (the side panel asking
      // whether to discard its draft before More options) is the dialog's.
      if (e.target.closest?.('[role="dialog"], dialog')) return;
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
    this.noticeKey = (e) => {
      if (e.key !== "Escape" || !this.notice) return;
      // Whatever is open behind the notice keeps its own Escape for the next press.
      e.stopPropagation();
      this.closeNotice();
    };
    // The server answered the create after all: its toast names the result
    // (with Undo where it can), so the doubt the notice voiced is over.
    this.handleEvent("calendar:create-settled", ({ draft }) => {
      if (this.notice && this.notice.dataset.draft === draft) this.closeNotice();
    });
    // More options waited on the panel's question about a draft with
    // uninvited guests; the organiser chose Discard, so it is chosen again.
    this.handleEvent("calendar:more-options-again", ({ draft }) => {
      if (this.draft?.id === draft) this.moreOptions();
    });
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
    this.closeNotice();
  },

  // The draft at the next free slot of the visible days, or of tomorrow late
  // in the evening; the command bar reads a line against its `base`.
  nextDraft() {
    const range = nextSlot(this.nowMinute(), this.createDays(), [...this.cache.events.values()], undefined, this.currentScale().firstMinute);
    return { ...draftFromRange(newDraftId(), range, this.defaultCalendar()), origin: "next" };
  },

  quickCreateNext() {
    if (!this.settings || !this.clock) return;
    if (this.quick) return this.quickFocus();
    // The preview would otherwise stay beside the draft.
    if (document.getElementById("calendar-preview")) this.pushEventTo(this.el, "calendar:close_preview", { refocus: "false" });
    this.startDraft(this.nextDraft());
    this.followDraft(0);
  },

  quickState() {
    return { draft: this.draft, strings: this.strings, timeFormat: this.settings.time_format, calendars: this.settings.calendars || [], meetingTypes: this.settings.meeting_types || [], hasAccounts: Boolean(this.settings.has_accounts), coarse: isCoarse() };
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
      element.addEventListener("calendar:dismiss", () => this.cancelQuickCreate({ restoreFocus: false }));
      document.body.appendChild(element);
      document.addEventListener("pointerdown", this.quickOutside);
    }
    this.placeQuickCreate();
    this.revealDraft();
    this.quickFocus();
  },

  quickField() {
    return this.quick.element.querySelector("#calendar-qc-field");
  },

  // The field, or the kind switch while an opening hides the field.
  quickFocus() {
    const field = this.quickField();
    const target = field.hidden ? this.quick.element.querySelector('[data-qc-key="kind-open"]') : field;
    target?.focus({ preventScroll: true });
  },

  // Forgets the popover; the draft is the caller's business.
  closeQuickCreate() {
    clearTimeout(this.followTimer);
    this.followTimer = null;
    document.removeEventListener("pointerdown", this.quickOutside);
    releaseSheet(this.quick?.element);
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
    this.revealDraft();
    this.followDraft();
  },

  quickInput(e) {
    if (e.target.id !== "calendar-qc-field" || this.draft?.status !== "editing") return;
    this.updateDraft(applyText(this.draft, e.target.value, this.parseOptions()));
  },

  quickChange(e) {
    const chip = e.target.dataset?.qcInput;
    if (!chip || this.draft?.status !== "editing") return;
    if (chip === "meetingType") return this.changeOpening(chip, e.target.value);
    return this.updateDraft(applyChip(this.draft, chip, e.target.value));
  },

  quickClick(e) {
    const target = e.target.closest("button");
    if (!target || !this.draft) return;
    if (target.dataset.qcPick) return this.openPicker(target);
    if (this.draft.status !== "editing") return undefined;
    if (target.dataset.qcKind) return this.toKind(target.dataset.qcKind);
    if (target.dataset.qcRepeat) return this.changeOpening("repeat", target.dataset.qcRepeat);
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
    this.quick.element.querySelector("[data-qc-head]").innerHTML = renderQuickHead(this.quickState());
    const field = this.quickField();
    field.readOnly = this.draft.status !== "editing";
    field.hidden = this.draft.kind === "open";
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
    // An opening hides the field; focus never stays on it.
    if (field.hidden && document.activeElement === field) this.quickFocus();
    this.placeQuickCreate();
  },

  // Beside the draft, never over it (calendar/popover.js); in the middle of
  // the grid while the draft is not drawn (its days still loading). On a
  // phone a bottom sheet (calendar/sheet.js).
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
    applyPlacement(element, placeOverlay(anchor, size, viewport(), { sheet: this.sheetMode() }));
  },

  // A sheet lies over the foot of the grid: the draft scrolls up to just
  // above it. Only on the hook's own changes (opening, a new draft state,
  // the follow, the keyboard), never on the organiser's scrolling.
  revealDraft() {
    if (!this.quick?.element.classList.contains("is-sheet") || !this.draft) return;
    const block = this.el.querySelector(draftSelector(this.draft.id));
    const scroller = this.el.querySelector("[data-scroll]");
    if (!block || !scroller) return;
    const header = this.el.querySelector(".cal-top");
    const limit = header ? header.getBoundingClientRect().bottom : scroller.getBoundingClientRect().top;
    scroller.scrollTop += sheetCovers(block.getBoundingClientRect(), this.quick.element.getBoundingClientRect(), limit);
  },

  // After a pause in typing (`delay`), brings the draft into view: the grid moves to
  // its day when that is not visible, else the draft scrolls into sight.
  followDraft(delay = FOLLOW_MS) {
    clearTimeout(this.followTimer);
    // Month and agenda draw no draft to bring into view (calendar_canvas/views.js).
    if (!isTimeGrid(this.view)) return;
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
      this.revealDraft();
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
    if (this.draft.kind === "open") return this.saveOpening();
    // No calendar to write to: the popover says so, and nothing is sent.
    if (!(this.settings.calendars || []).length) return;
    this.updateDraft({ ...this.draft, status: "saving", error: null });
    const { id } = this.draft;
    this.pushGuarded("calendar:create", toPayload(this.draft), (reply) => this.createReplied(id, reply), () => this.createLost(id));
  },

  // The save's reply will not come, yet the server may have written the
  // event (and emailed its guests), so saving again could create it twice.
  // The draft goes; the reload after a reconnect, or the server's next
  // payload, shows the event if it landed.
  createLost(id, text = this.strings.create_unconfirmed) {
    if (this.draft?.id !== id) return;
    const returnTo = this.quick?.returnTo;
    this.closeQuickCreate();
    this.draft = null;
    this.render();
    this.restoreQuickFocus(returnTo);
    this.showNotice(text, id);
  },

  // A message of the hook's own, shaped like the surface's toast, for news
  // the server cannot deliver (its connection is in doubt), about the draft
  // `draft`. Appended to <body>, as the popover is, so no redraw removes it.
  // It leaves on its own, with its button, with Escape, or once the server
  // settles that draft after all.
  showNotice(text, draft) {
    this.closeNotice();
    const notice = document.createElement("div");
    notice.id = "calendar-notice";
    notice.className = "cal-notice";
    notice.dataset.draft = draft;
    notice.setAttribute("role", "alert");
    const message = document.createElement("span");
    message.className = "cal-notice-text";
    message.textContent = text;
    const close = document.createElement("button");
    close.type = "button";
    close.className = "cal-notice-close";
    close.setAttribute("aria-label", this.strings.dismiss);
    const icon = document.createElement("span");
    icon.className = "hero-x-mark-mini cal-notice-icon";
    icon.setAttribute("aria-hidden", "true");
    close.append(icon);
    close.addEventListener("click", () => this.closeNotice());
    notice.append(message, close);
    document.body.append(notice);
    this.notice = notice;
    this.noticeTimer = setTimeout(() => this.closeNotice(), NOTICE_MS);
    document.addEventListener("keydown", this.noticeKey);
  },

  closeNotice() {
    clearTimeout(this.noticeTimer);
    this.noticeTimer = null;
    document.removeEventListener("keydown", this.noticeKey);
    this.notice?.remove();
    this.notice = null;
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
    if (this.quick) this.quickFocus();
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
