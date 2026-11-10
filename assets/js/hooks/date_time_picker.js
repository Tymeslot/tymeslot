/**
 * The behaviour of `<.date_picker>`, `<.time_picker>` and `<.datetime_picker>`
 * (`core_components/date_time_picker.ex`): a typed field with a button that
 * opens an ARIA date-picker dialog or a listbox of times, posting through a
 * hidden input.
 *
 * As with `<.select>`, a touch device and a browser without the Popover API
 * use the native control instead (the switch is CSS; the hook only keeps the
 * two in step), and every choice ends the same way: the hidden input takes the
 * ISO value and fires `input`, which is what LiveView's `phx-change` hears.
 */

import { floatingPanelsSupported, openFloatingPanel } from "../floating_panel";
import { typeAheadIndex } from "./select";
import {
  addDays,
  addMonths,
  endOfWeek,
  formatDate,
  formatTime,
  monthMatrix,
  parseDate,
  parseIso,
  parseTime,
  startOfWeek,
  todayIso,
} from "../date_time_format";

const PAGE_STEP = 8;
const TYPE_AHEAD_RESET_MS = 500;

// Where an empty time list opens. Only a highlight: nothing is chosen until
// the visitor chooses it.
const DEFAULT_TIME = "09:00";

export const DateTimePicker = {
  mounted() {
    // Every listener goes with this, so a field that changes kind can be built
    // again from scratch without the old parts still answering.
    this.abort = new AbortController();
    this.kind = this.el.dataset.pickerKind;
    this.config = JSON.parse(this.el.dataset.pickerConfig);
    this.valueInput = this.el.querySelector("[data-picker-value]");
    this.native = this.el.querySelector("[data-picker-native]");
    this.parts = Array.from(this.el.querySelectorAll("[data-picker-part]")).map((root) =>
      this.buildPart(root)
    );

    this.serverValue = this.valueInput.value;
    this.chosenValue = null;
    this.state = this.splitValue(this.valueInput.value);

    this.markFallback();

    this.onNativeChoice = (event) => this.handleNativeChoice(event);
    this.onLabelClick = (event) => this.handleLabelClick(event);
    const { signal } = this.abort;

    this.native.addEventListener("input", this.onNativeChoice, { signal });
    this.native.addEventListener("change", this.onNativeChoice, { signal });
    this.el.addEventListener("click", this.onLabelClick, { signal });

    // `autofocus` is on the typed field; where the native control is the one
    // on show, it takes the focus instead.
    if (this.parts[0]?.text.hasAttribute("autofocus") && this.nativeActive()) this.native.focus();
  },

  updated() {
    // The same element can come back as another kind (a question switched
    // from Date to Time): start again rather than drive the new markup with
    // the old parts.
    if (this.el.dataset.pickerKind !== this.kind) {
      this.destroyed();
      this.mounted();
      return;
    }

    this.config = JSON.parse(this.el.dataset.pickerConfig);
    this.markFallback();
    this.syncFromServer();
    this.renderTexts();

    this.parts.forEach((part) => {
      part.trigger.setAttribute("aria-expanded", part.open ? "true" : "false");
      if (part.open) part.open.reposition();
    });
  },

  destroyed() {
    this.parts.forEach((part) => this.close(part, false));
    this.abort.abort();
  },

  nativeActive() {
    return getComputedStyle(this.native).display !== "none";
  },

  markFallback() {
    if (!floatingPanelsSupported()) this.el.dataset.pickerForceNative = "";
  },

  buildPart(root) {
    const part = {
      name: root.dataset.pickerPart,
      root,
      text: root.querySelector("[data-picker-text]"),
      trigger: root.querySelector("[data-picker-trigger]"),
      panel: root.querySelector("[data-picker-panel]"),
      open: null,
      activeDate: null,
      activeIndex: -1,
      options: [],
      typed: "",
      typedAt: 0,
      moved: false,
    };

    const { signal } = this.abort;
    const on = (target, type, handler) => target.addEventListener(type, handler, { signal });

    on(part.text, "input", (event) => event.stopPropagation());
    on(part.text, "change", (event) => {
      event.stopPropagation();
      this.commitText(part);
    });
    on(part.text, "keydown", (event) => this.handleTextKey(part, event));
    on(part.trigger, "click", () => this.toggle(part));
    on(part.panel, "keydown", (event) => this.handlePanelKey(part, event));
    on(part.panel, "click", (event) => this.handlePanelClick(part, event));
    on(part.panel, "focusout", (event) => this.handleFocusOut(part, event));

    if (part.name === "time") on(part.panel, "pointermove", (event) => this.handleTimeMove(part, event));

    return part;
  },

  // The field's value as the parts the visitor edits separately.
  splitValue(value) {
    if (this.kind === "date") return { date: value, time: "" };
    if (this.kind === "time") return { date: "", time: value.slice(0, 5) };

    const [date = "", time = ""] = value.split("T");
    return { date, time: time.slice(0, 5) };
  },

  composeValue() {
    const { date, time } = this.state;

    if (this.kind === "date") return date;
    if (this.kind === "time") return time;
    return date !== "" && time !== "" ? `${date}T${time}` : "";
  },

  // A patch writes the server's value back over the hidden input. If the
  // server has moved on, its value stands, unless it is only echoing what the
  // visitor has half filled in. If not, this is a re-render for some other
  // reason, and the visitor's choice is kept.
  syncFromServer() {
    const rendered = this.valueInput.value;

    if (rendered !== this.serverValue) {
      this.serverValue = rendered;
      this.chosenValue = null;
      if (rendered !== this.composeValue()) this.state = this.splitValue(rendered);
    } else if (this.chosenValue !== null && this.chosenValue !== rendered) {
      this.valueInput.value = this.chosenValue;
    }
  },

  renderTexts() {
    this.native.value = this.composeValue();

    this.parts.forEach((part) => {
      if (document.activeElement === part.text) return;
      part.text.value = this.formatPart(part.name);
    });
  },

  formatPart(name) {
    return name === "date"
      ? formatDate(this.state.date, this.config)
      : formatTime(this.state.time, this.config.timeFormat);
  },

  setPart(name, value) {
    this.state[name] = value;
    this.commit();
  },

  commit() {
    const value = this.composeValue();

    this.renderTexts();

    if (value === this.valueInput.value) return;

    this.chosenValue = value;
    this.valueInput.value = value;
    this.valueInput.dispatchEvent(new Event("input", { bubbles: true }));
  },

  // What was typed becomes the value when it can be read; when it cannot, the
  // field goes back to the last good value rather than post something else.
  commitText(part) {
    const parsed =
      part.name === "date" ? parseDate(part.text.value, this.config) : parseTime(part.text.value);

    if (parsed !== null) this.setPart(part.name, parsed);

    // Written back even while the field has focus, so the visitor sees how
    // their text was read (or that it could not be).
    part.text.value = this.formatPart(part.name);
  },

  // The native control answers on the hidden input instead, so its own events
  // must not reach LiveView's form listeners with the old value.
  handleNativeChoice(event) {
    event.stopPropagation();
    this.state = this.splitValue(this.native.value);
    this.commit();
  },

  handleLabelClick(event) {
    if (!event.target.closest("label")) return;

    event.preventDefault();
    this.focusField();
  },

  focusField() {
    const target = this.nativeActive() ? this.native : this.parts[0].text;

    target.focus();
  },

  // Enter takes what was typed and lets the form submit, if it has a submit to
  // run: a form that only `phx-change`s has nothing to do with it.
  handleTextKey(part, event) {
    if (event.key === "Enter") {
      this.commitText(part);
      if (!part.text.form?.hasAttribute("phx-submit")) event.preventDefault();
    } else if (event.key === "ArrowDown") {
      event.preventDefault();
      this.show(part);
    }
  },

  toggle(part) {
    if (part.open) {
      this.close(part, true);
    } else {
      this.show(part);
    }
  },

  show(part) {
    if (part.open || part.trigger.disabled) return;

    this.parts.forEach((other) => other !== part && this.close(other, false));

    if (part.name === "date") {
      this.prepareDatePanel(part);
    } else {
      this.prepareTimePanel(part);
    }

    const handle = openFloatingPanel({
      panel: part.panel,
      anchor: part.root,
      // A month grid has its own width; a time list takes the field's.
      matchAnchorWidth: part.name === "time",
      onDismiss: (reason) => this.afterClose(part, reason !== "outside"),
    });

    // It closes itself at once when the field is out of view.
    if (handle.closed()) return;

    part.open = handle;
    part.trigger.setAttribute("aria-expanded", "true");

    if (part.name === "date") {
      this.focusActiveDay(part);
    } else {
      part.panel.focus({ preventScroll: true });
      this.renderActiveTime(part);
    }
  },

  close(part, returnFocus) {
    if (!part.open) return;

    part.open.close();
    this.afterClose(part, returnFocus);
  },

  afterClose(part, returnFocus) {
    part.open = null;
    part.trigger.setAttribute("aria-expanded", "false");
    part.panel.removeAttribute("aria-activedescendant");
    part.typed = "";

    if (returnFocus && this.el.isConnected) part.trigger.focus({ preventScroll: true });
  },

  // Focus leaving the panel closes it (a press elsewhere is the pointerdown's
  // business); a tab away from the window is not leaving it, and pressing the
  // button must not close it here or that click would open it again.
  handleFocusOut(part, event) {
    const next = event.relatedTarget;

    if (next && !part.panel.contains(next) && !part.trigger.contains(next)) this.close(part, false);
  },

  handlePanelClick(part, event) {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;

    if (part.name === "time") {
      const index = this.timeIndex(part, target);
      if (index >= 0) this.chooseTime(part, index);
      return;
    }

    if (target.closest("[data-picker-prev]")) {
      this.stepMonth(part, -1, false);
    } else if (target.closest("[data-picker-next]")) {
      this.stepMonth(part, 1, false);
    } else {
      const day = target.closest("[data-date]");
      if (day) this.chooseDate(part, day.dataset.date);
    }
  },

  handlePanelKey(part, event) {
    if (part.name === "date") {
      this.handleDateKey(part, event);
    } else {
      this.handleTimeKey(part, event);
    }
  },

  // ---- The date dialog ---------------------------------------------------

  prepareDatePanel(part) {
    part.activeDate = parseIso(this.state.date) ? this.state.date : this.clampToRange(todayIso());
    this.renderMonth(part);
  },

  // Today, unless the field cannot take it: then the nearest day it can.
  clampToRange(iso) {
    const min = this.native.min.slice(0, 10);
    const max = this.native.max.slice(0, 10);

    if (min !== "" && iso < min) return min;
    if (max !== "" && iso > max) return max;
    return iso;
  },

  renderMonth(part) {
    const { year, month } = parseIso(part.activeDate);
    const { monthHeadings, weekStart, locale } = this.config;
    const heading = part.panel.querySelector("[data-picker-month]");
    const body = part.panel.querySelector("[data-picker-days]");
    const today = todayIso();
    const dateLabel = new Intl.DateTimeFormat(locale, { dateStyle: "full", timeZone: "UTC" });
    const rows = [];

    heading.textContent = monthHeadings[month - 1].replace("{y}", String(year));

    monthMatrix(year, month, weekStart).forEach((iso, index) => {
      if (index % 7 === 0) rows.push(document.createElement("tr"));

      const day = parseIso(iso);
      const cell = document.createElement("td");
      const button = document.createElement("button");

      cell.setAttribute("role", "gridcell");
      button.type = "button";
      button.dataset.date = iso;
      button.tabIndex = iso === part.activeDate ? 0 : -1;
      button.textContent = String(day.day);
      button.className = "date-picker-day";
      button.setAttribute(
        "aria-label",
        dateLabel.format(new Date(Date.UTC(day.year, day.month - 1, day.day)))
      );

      if (day.month !== month) button.classList.add("date-picker-day--outside");
      if (iso === today) button.setAttribute("aria-current", "date");

      if (iso === this.state.date) {
        button.classList.add("is-selected");
        button.setAttribute("aria-pressed", "true");
      }

      if (this.outOfRange(iso)) button.setAttribute("aria-disabled", "true");

      cell.appendChild(button);
      rows[rows.length - 1].appendChild(cell);
    });

    body.replaceChildren(...rows);
  },

  outOfRange(iso) {
    const { min, max } = this.native;

    return (min !== "" && iso < min.slice(0, 10)) || (max !== "" && iso > max.slice(0, 10));
  },

  focusActiveDay(part) {
    const day = part.panel.querySelector(`[data-date="${part.activeDate}"]`);

    if (day) day.focus({ preventScroll: true });
  },

  moveDay(part, iso) {
    const current = parseIso(part.activeDate);
    const next = parseIso(iso);

    part.activeDate = iso;

    if (current.year !== next.year || current.month !== next.month) {
      this.renderMonth(part);
    } else {
      part.panel.querySelectorAll("[data-date]").forEach((button) => {
        button.tabIndex = button.dataset.date === iso ? 0 : -1;
      });
    }

    this.focusActiveDay(part);
  },

  // The header's arrows re-draw and leave focus on themselves; a key moves the
  // grid's own focus with it.
  stepMonth(part, months, moveFocus) {
    part.activeDate = addMonths(part.activeDate, months);
    this.renderMonth(part);
    if (moveFocus) this.focusActiveDay(part);
  },

  chooseDate(part, iso) {
    if (this.outOfRange(iso)) return;

    this.close(part, true);
    this.setPart("date", iso);
  },

  handleDateKey(part, event) {
    const { weekStart } = this.config;
    const inGrid = event.target instanceof Element && event.target.closest("[data-date]");

    switch (event.key) {
      case "Tab":
        this.trapTab(part, event);
        break;
      case "ArrowLeft":
      case "ArrowRight":
      case "ArrowUp":
      case "ArrowDown":
      case "Home":
      case "End":
      case "PageUp":
      case "PageDown":
        if (inGrid) {
          event.preventDefault();
          this.moveByKey(part, event, weekStart);
        }
        break;
      case "Enter":
      case " ":
        if (inGrid) {
          event.preventDefault();
          this.chooseDate(part, inGrid.dataset.date);
        }
        break;
      default:
    }
  },

  moveByKey(part, event, weekStart) {
    const { activeDate } = part;
    const dayDeltas = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 };

    if (event.key in dayDeltas) {
      this.moveDay(part, addDays(activeDate, dayDeltas[event.key]));
    } else if (event.key === "Home") {
      this.moveDay(part, startOfWeek(activeDate, weekStart));
    } else if (event.key === "End") {
      this.moveDay(part, endOfWeek(activeDate, weekStart));
    } else {
      const direction = event.key === "PageUp" ? -1 : 1;

      this.stepMonth(part, direction * (event.shiftKey ? 12 : 1), true);
    }
  },

  // The dialog keeps Tab to itself: the arrows, then the grid's one tab stop.
  trapTab(part, event) {
    const stops = Array.from(part.panel.querySelectorAll("button")).filter(
      (button) => button.tabIndex === 0 && !button.disabled
    );
    const index = stops.indexOf(event.target);

    event.preventDefault();
    stops[(index + (event.shiftKey ? -1 : 1) + stops.length) % stops.length]?.focus();
  },

  // ---- The time list -----------------------------------------------------

  prepareTimePanel(part) {
    part.options = this.config.timeOptions.map(([label, value], index) => {
      const el = document.createElement("div");

      el.id = `${part.panel.id}-option-${index}`;
      el.setAttribute("role", "option");
      el.setAttribute("aria-selected", value === this.state.time ? "true" : "false");
      el.className = "select-option";
      el.textContent = label;

      const disabled = this.timeOutOfRange(value);
      if (disabled) el.setAttribute("aria-disabled", "true");

      return { label, value, el, disabled };
    });

    part.panel.replaceChildren(...part.options.map(({ el }) => el));
    part.activeIndex = this.nearestTimeIndex(part);
    part.moved = false;
  },

  // A time field's own limits; a combined field's limits are dates.
  timeOutOfRange(value) {
    if (this.kind !== "time") return false;

    const min = this.native.min.slice(0, 5);
    const max = this.native.max.slice(0, 5);

    return (min !== "" && value < min) || (max !== "" && value > max);
  },

  // The current value's slot, or the first after it, so a value off the
  // quarter-hour grid opens where it would sit.
  nearestTimeIndex(part) {
    const wanted = this.state.time === "" ? DEFAULT_TIME : this.state.time;
    const index = part.options.findIndex(({ value, disabled }) => value >= wanted && !disabled);

    if (index >= 0) return index;
    return this.enabledTime(part, part.options.length, -1);
  },

  // The nearest selectable time from `from` (exclusive) in `direction`, or
  // `from` itself when there is none that way.
  enabledTime(part, from, direction) {
    for (let index = from + direction; index >= 0 && index < part.options.length; index += direction) {
      if (!part.options[index].disabled) return index;
    }

    return from;
  },

  renderActiveTime(part) {
    part.options.forEach(({ el }, index) => {
      el.classList.toggle("is-active", index === part.activeIndex);
    });

    const active = part.options[part.activeIndex]?.el;

    if (active) {
      part.panel.setAttribute("aria-activedescendant", active.id);
      active.scrollIntoView({ block: "nearest" });
    }
  },

  moveTime(part, index) {
    const clamped = Math.max(0, Math.min(part.options.length - 1, index));
    const direction = clamped >= part.activeIndex ? 1 : -1;
    let target = clamped;

    // A disabled time: the next one on the way, else the nearest back.
    if (part.options[target]?.disabled) target = this.enabledTime(part, clamped, direction);
    if (part.options[target]?.disabled) target = this.enabledTime(part, clamped, -direction);

    if (part.options[target] && !part.options[target].disabled) part.activeIndex = target;
    this.renderActiveTime(part);
  },

  chooseTime(part, index) {
    const option = part.options[index];
    if (!option || option.disabled) return;

    this.close(part, true);
    this.setPart("time", option.value);
  },

  timeIndex(part, target) {
    const option = target.closest("[role='option']");

    return option ? part.options.findIndex(({ el }) => el === option) : -1;
  },

  handleTimeMove(part, event) {
    const index = event.target instanceof Element ? this.timeIndex(part, event.target) : -1;

    if (index >= 0 && index !== part.activeIndex && !part.options[index].disabled) {
      part.activeIndex = index;
      this.renderActiveTime(part);
    }
  },

  handleTimeKey(part, event) {
    const moves = {
      ArrowDown: part.activeIndex + 1,
      ArrowUp: part.activeIndex - 1,
      Home: 0,
      End: part.options.length - 1,
      PageDown: part.activeIndex + PAGE_STEP,
      PageUp: part.activeIndex - PAGE_STEP,
    };

    if (event.key in moves) {
      event.preventDefault();
      part.moved = true;
      this.moveTime(part, moves[event.key]);
    } else if (event.key === "Enter" || event.key === " ") {
      event.preventDefault();
      this.chooseTime(part, part.activeIndex);
    } else if (event.key === "Tab") {
      // A time the visitor picked out with the keys is taken, as a native list
      // does; the highlight the list merely opened on is not, or tabbing past
      // an optional field would answer it. Focus goes back to the button for
      // the browser to move on from.
      if (part.moved) {
        this.chooseTime(part, part.activeIndex);
      } else {
        this.close(part, true);
      }
    } else if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault();
      this.typeAhead(part, event.key);
    }
  },

  typeAhead(part, char) {
    const now = Date.now();

    if (now - part.typedAt > TYPE_AHEAD_RESET_MS) part.typed = "";
    part.typedAt = now;
    part.typed += char.toLowerCase();

    const index = typeAheadIndex(part.options, part.typed, part.activeIndex);

    if (index >= 0) {
      part.moved = true;
      this.moveTime(part, index);
    }
  },
};
