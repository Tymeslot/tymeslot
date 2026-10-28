/**
 * The command bar, for the CalendarCanvas hook (mixed into it).
 *
 * The bar (#calendar-command, CommandBar) is rendered by the server outside
 * the canvas and stays in the page, closed. Ctrl K or Cmd K opens and closes
 * it from anywhere, text fields and quick create included (quick create is
 * cancelled as Escape would), but never during a live drag or over an open
 * core modal; `/` opens it where the single-key shortcuts work; the
 * toolbar's and the phone header's search buttons dispatch
 * `calendar:command-open` on the canvas. Opening runs the bar's `data-show`
 * JS command (it sets `data-open`, which LiveView keeps through patches) and
 * focuses the input; closing runs `data-hide` (which also pushes
 * `calendar:command_close`) and gives focus back to where it was, unless
 * the chosen row moves it.
 *
 * While it is open this mixin owns the keyboard, in a capture listener that
 * runs before every other: Escape closes it (and nothing else sees that
 * Escape), Up and Down move through the rows and wrap, Home and End jump to
 * the ends, Enter runs the active row or the first, Tab stays inside the
 * bar. The rows are one list across the hook's own groups
 * (#calendar-command-instant before the server's #calendar-command-results,
 * #calendar-command-after after them); the active one is marked with
 * `aria-selected` and named by the input's `aria-activedescendant`, which a
 * MutationObserver puts back whenever a LiveView patch takes them off.
 *
 * The hook's own rows (calendar/commands.js) are drawn on every keystroke:
 * a typed date, "Add …", the matching commands. A command runs here
 * (views, Today, next and previous through `gotoPeriod`; New event; the
 * bookable layer; pushes to the surface or, for focus mode and the old
 * calendar, to DashboardLive). "Add …" opens quick create filled in from the
 * line. A server row reveals its event (reveal.js); the preview then takes focus.
 */
import { addRow, commandRows, dateRow } from "../../calendar/commands.js";
import { applyText } from "../../calendar/draft.js";
import { escapeHtml } from "../../calendar/render.js";
import { revealRequest } from "../../calendar/reveal.js";
import { POWER_KEYS, WIDE } from "./power_keys.js";
import { CORE_MODAL_OPEN, isCommandKey, plainKeyAllowed } from "../../calendar/shortcuts.js";

const OPTION = '[role="option"]';
const ROWS = `#calendar-command-instant ${OPTION}, #calendar-command-results ${OPTION}, #calendar-command-after ${OPTION}`;
const FOCUSABLE = "#calendar-command-input, [data-command-close]";
const STEPS = { ArrowDown: 1, ArrowUp: -1 };

// A core modal (<.modal>) is open: its overlay is shown (Task 3's marker).
const coreModalOpen = () => document.querySelector(CORE_MODAL_OPEN) !== null;

// One of the hook's own rows; `index` maps its command id back to the row.
function instantHtml(row, index) {
  index.set(row.id, row);
  const hint = row.hint ? `<span class="cal-command-row-meta">${escapeHtml(row.hint)}</span>` : "";
  const keys = row.keys ? `<kbd>${escapeHtml(row.keys)}</kbd>` : "";
  return (
    `<button type="button" role="option" tabindex="-1" id="calendar-command-row-c${index.size}" class="cal-command-row" data-command-row="${escapeHtml(row.id)}">` +
    `<span class="cal-command-row-main"><span class="cal-command-row-title">${escapeHtml(row.label)}</span>${hint}</span>${keys}</button>`
  );
}

export const CommandMixin = {
  mountCommand() {
    this.commandReturn = null;
    this.commandActive = null;
    this.commandObserver = null;
    this.commandCapture = (e) => this.commandCaptureKey(e);
    this.commandSlash = (e) => {
      if (e.key !== "/" || !plainKeyAllowed(e, this)) return;
      e.preventDefault();
      this.openCommand();
    };
    this.commandOpenEvent = () => this.openCommand();
    this.commandClick = (e) => this.commandClicked(e);
    // A click on the panel's dead space must not pull focus out of the input.
    this.commandMouseDown = (e) => {
      if (this.commandOpen() && e.target?.closest?.(".cal-command-panel") && !e.target.closest(`${FOCUSABLE}, ${OPTION}`)) e.preventDefault();
    };
    this.commandTyped = (e) => {
      if (e.target.id !== "calendar-command-input") return;
      this.commandActive = null;
      this.renderInstant(e.target.value);
      this.syncActive();
    };
    document.addEventListener("keydown", this.commandCapture, true);
    document.addEventListener("keydown", this.commandSlash);
    document.addEventListener("click", this.commandClick);
    document.addEventListener("mousedown", this.commandMouseDown);
    document.addEventListener("input", this.commandTyped);
    this.el.addEventListener("calendar:command-open", this.commandOpenEvent);
    const bar = this.commandBar();
    if (bar && typeof MutationObserver !== "undefined") {
      this.commandObserver = new MutationObserver(() => this.syncActive());
      this.commandObserver.observe(bar, { subtree: true, childList: true, attributes: true, attributeFilter: ["aria-selected", "aria-activedescendant", "aria-expanded"] });
    }
  },

  destroyCommand() {
    document.removeEventListener("keydown", this.commandCapture, true);
    document.removeEventListener("keydown", this.commandSlash);
    document.removeEventListener("click", this.commandClick);
    document.removeEventListener("mousedown", this.commandMouseDown);
    document.removeEventListener("input", this.commandTyped);
    this.el.removeEventListener("calendar:command-open", this.commandOpenEvent);
    this.commandObserver?.disconnect();
    this.commandObserver = null;
  },

  commandBar() {
    return document.getElementById("calendar-command");
  },

  commandField() {
    return document.getElementById("calendar-command-input");
  },

  commandOpen() {
    return Boolean(this.commandBar()?.hasAttribute("data-open"));
  },

  commandRows() {
    return [...(this.commandBar()?.querySelectorAll(ROWS) ?? [])];
  },

  commandCaptureKey(e) {
    if (isCommandKey(e)) {
      // Taken before the guards, so a held Ctrl K never reaches the browser's own search.
      e.preventDefault();
      e.stopPropagation();
      if (e.repeat || e.isComposing || this.drag || this.createDrag || coreModalOpen()) return;
      if (this.commandOpen()) this.closeCommand();
      else this.openCommand();
      return;
    }
    if (!this.commandOpen() || e.isComposing) return;
    if (e.key === "Escape") {
      e.preventDefault();
      e.stopPropagation();
      this.closeCommand();
      return;
    }
    if (STEPS[e.key] || e.key === "Home" || e.key === "End" || e.key === "Tab") {
      e.preventDefault();
      e.stopPropagation();
      const inside = e.target?.closest?.("#calendar-command");
      if (!inside) this.commandField()?.focus({ preventScroll: true });
      else if (e.key === "Tab") this.cycleCommandFocus(e.shiftKey ? -1 : 1);
      else if (STEPS[e.key]) this.moveActive(STEPS[e.key]);
      else this.setActive(e.key === "Home" ? this.commandRows()[0] : this.commandRows().at(-1));
      return;
    }
    // Enter on the close button is the button's own.
    if (e.key === "Enter" && e.target?.closest?.("#calendar-command") && !e.target.closest("[data-command-close]")) {
      e.preventDefault();
      e.stopPropagation();
      // Server rows wait for a search still running; the hook's own rows never do.
      const busy = document.getElementById("calendar-command-results")?.getAttribute("aria-busy") === "true";
      const rows = this.commandRows().filter((row) => !busy || !row.closest("#calendar-command-results, #calendar-command-after"));
      this.runRow(rows.find((row) => row.id === this.commandActive) ?? (this.commandActive && busy ? undefined : rows[0]));
    }
  },

  openCommand() {
    const bar = this.commandBar();
    if (!bar || this.commandOpen()) return;
    // First, so focus inside a "+N" list has moved to its anchor before it is kept.
    this.closeList();
    const active = document.activeElement;
    this.commandReturn = this.quick ? this.quick.returnTo : active && active !== document.body ? active : null;
    if (this.quick) this.cancelQuickCreate({ restoreFocus: false });
    if (this.moving) this.cancelMove({ announce: false });
    // Rows a closed bar still holds (a late answer to a debounced query) go.
    if (bar.querySelector(`#calendar-command-results ${OPTION}`)) this.pushEventTo(this.el, "calendar:command_query", { q: "" });
    this.liveSocket.execJS(bar, bar.dataset.show);
    const field = this.commandField();
    field.value = "";
    this.commandActive = null;
    this.renderInstant("");
    this.syncActive();
    field.focus({ preventScroll: true });
  },

  closeCommand({ restoreFocus = true } = {}) {
    const bar = this.commandBar();
    if (!bar || !this.commandOpen()) return;
    this.liveSocket.execJS(bar, bar.dataset.hide);
    this.commandField().value = "";
    this.clearInstant();
    this.commandActive = null;
    this.syncActive();
    const returnTo = this.commandReturn;
    this.commandReturn = null;
    if (!restoreFocus) return;
    const fallback = document.getElementById(this.phone ? "calendar-phone-search" : "calendar-search");
    (returnTo?.isConnected ? returnTo : fallback)?.focus({ preventScroll: true });
  },

  clearInstant() {
    for (const id of ["calendar-command-instant", "calendar-command-after"]) {
      const group = document.getElementById(id);
      if (group) group.innerHTML = "";
    }
  },

  // The hook's own rows, in the bar's order: a typed date, "Add …" when the
  // line says when, the matching commands; after the server's rows, "Add …"
  // when it did not go first.
  renderInstant(query) {
    this.clearInstant();
    this.instantRows = new Map();
    if (!this.settings || !this.clock) return;
    const base = String(query ?? "").trim().length > 1 ? this.nextDraft().base : undefined;
    const opts = { ...this.parseOptions(), base, strings: this.strings, timeFormat: this.settings.time_format };
    const add = addRow(query, opts);
    const commands = commandRows(query, { settings: this.settings, strings: this.strings, phone: Boolean(this.phone), wide: Boolean(window.matchMedia?.(WIDE)?.matches) });
    this.fillGroup("calendar-command-instant", [dateRow(query, opts), add?.first ? add : null, ...commands].filter(Boolean));
    this.fillGroup("calendar-command-after", add && !add.first ? [add] : []);
  },

  fillGroup(id, rows) {
    const group = document.getElementById(id);
    if (group) group.innerHTML = rows.map((row) => instantHtml(row, this.instantRows)).join("");
  },

  moveActive(step) {
    const rows = this.commandRows();
    if (!rows.length) return;
    const index = rows.findIndex((row) => row.id === this.commandActive);
    const next = index === -1 ? (step > 0 ? 0 : rows.length - 1) : (index + step + rows.length) % rows.length;
    this.setActive(rows[next]);
  },

  setActive(row) {
    this.commandActive = row?.id ?? null;
    this.syncActive();
    row?.scrollIntoView?.({ block: "nearest" });
  },

  // Marks the active row and names it on the input. Only differences are
  // written, so the observer's own callback settles at once.
  syncActive() {
    const rows = this.commandRows();
    if (this.commandActive && !rows.some((row) => row.id === this.commandActive)) this.commandActive = null;
    for (const row of rows) {
      const selected = String(row.id === this.commandActive);
      if (row.getAttribute("aria-selected") !== selected) row.setAttribute("aria-selected", selected);
    }
    const field = this.commandField();
    if (!field) return;
    const expanded = String(rows.length > 0);
    if (field.getAttribute("aria-expanded") !== expanded) field.setAttribute("aria-expanded", expanded);
    if (this.commandActive && field.getAttribute("aria-activedescendant") !== this.commandActive) field.setAttribute("aria-activedescendant", this.commandActive);
    else if (!this.commandActive && field.hasAttribute("aria-activedescendant")) field.removeAttribute("aria-activedescendant");
  },

  cycleCommandFocus(step) {
    const items = [...this.commandBar().querySelectorAll(FOCUSABLE)];
    if (!items.length) return;
    const index = items.indexOf(document.activeElement);
    items[(index + step + items.length) % items.length].focus();
  },

  commandClicked(e) {
    if (!this.commandOpen()) return;
    if (e.target.closest?.("[data-command-scrim], [data-command-close]")) {
      this.closeCommand();
      return;
    }
    const row = e.target.closest?.(`#calendar-command ${OPTION}`);
    if (row) this.runRow(row);
  },

  runRow(row) {
    if (!row) return undefined;
    if (row.hasAttribute("data-command-result")) {
      this.closeCommand({ restoreFocus: false });
      return this.revealEvent(revealRequest(row.dataset));
    }
    const command = this.instantRows?.get(row.dataset.commandRow);
    return command ? this.runCommand(command) : undefined;
  },

  runCommand(command) {
    if (command.id === "goto") return this.leaveForGrid(() => this.gotoPeriod(this.periodFrom().view, command.date));
    if (command.id === "add") return this.addFromLine(command.text);
    const { run } = command;
    const from = this.periodFrom();
    switch (run.type) {
      case "view":
        return this.leaveForGrid(() => from.view !== run.view && this.switchView(run.view, from));
      case "key":
        // T and J/K move the grid; the rest (F, ?, the digits) leave focus where it was.
        if ("tjk".includes(run.key)) return this.leaveForGrid(() => POWER_KEYS[run.key](this));
        this.closeCommand();
        return POWER_KEYS[run.key](this);
      case "create":
        this.closeCommand({ restoreFocus: false });
        return this.quickCreateNext();
      case "bookable":
        this.closeCommand();
        return this.toggleBookable();
      case "push":
        this.closeCommand();
        return this.pushEventTo(this.el, run.event, run.params);
      default:
        return this.closeCommand();
    }
  },

  // A row that moves the grid leaves focus on the grid, not where it was.
  leaveForGrid(move) {
    this.closeCommand({ restoreFocus: false });
    move();
    this.restoreQuickFocus(null);
  },

  // Quick create at the next free time, read from the typed line: one more
  // Enter saves it.
  addFromLine(text) {
    this.closeCommand({ restoreFocus: false });
    this.quickCreateNext();
    if (!this.quick || !this.draft) return;
    this.quickField().value = text;
    this.updateDraft(applyText(this.draft, text, this.parseOptions()));
    this.quickFocus();
  },
};
