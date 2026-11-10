/**
 * The behaviour of `<.select>` (`core_components/select.ex`): an ARIA listbox
 * opened from a button, with keyboard, type-ahead and focus management, that
 * posts through a hidden input.
 *
 * The server renders the options once, inside the native `<select>`: on a
 * touch device that control is what the visitor uses (the system picker beats
 * any custom list there, and the switch is made in CSS on `pointer: coarse`),
 * and elsewhere the list is drawn from it each time it opens, so the two can
 * never disagree and a long option list is not sent twice.
 *
 * Either way a choice ends the same way: the hidden input takes the value and
 * fires `input`, which is what LiveView's `phx-change` listens for.
 */

import { floatingPanelsSupported, openFloatingPanel } from "../floating_panel";

const TYPE_AHEAD_RESET_MS = 500;
const PAGE_STEP = 10;

/**
 * The option a type-ahead buffer lands on.
 *
 * A buffer of one repeated character cycles through the options starting with
 * it, as a native select does; anything longer matches from the current option
 * onwards.
 *
 * @param {Array<{label: string, disabled: boolean}>} options
 * @param {string} buffer what has been typed, lower-cased
 * @param {number} from the index of the active option
 * @returns {number} the matching index, or -1
 */
export function typeAheadIndex(options, buffer, from) {
  if (buffer === "" || options.length === 0) return -1;

  const repeated = [...buffer].every((char) => char === buffer[0]);
  const needle = repeated ? buffer[0] : buffer;
  const start = repeated ? from + 1 : Math.max(from, 0);

  for (let step = 0; step < options.length; step += 1) {
    const index = (start + step) % options.length;
    const { label, disabled } = options[index];

    if (!disabled && label.trim().toLowerCase().startsWith(needle)) return index;
  }

  return -1;
}

export const Select = {
  mounted() {
    this.valueInput = this.el.querySelector("[data-select-value]");
    this.trigger = this.el.querySelector("[data-select-trigger]");
    this.native = this.el.querySelector("[data-select-native]");
    this.panel = this.el.querySelector("[data-select-panel]");
    this.valueText = this.el.querySelector("[data-select-text]");

    this.open = null;
    this.options = [];
    this.activeIndex = -1;
    this.typed = "";
    this.typedAt = 0;

    // The value the server last rendered, and a choice it has not echoed yet.
    this.serverValue = this.valueInput.value;
    this.chosenValue = null;

    if (!floatingPanelsSupported()) this.el.dataset.selectForceNative = "";

    this.onTriggerClick = () => (this.open ? this.close(true) : this.show());
    this.onTriggerKeydown = (event) => this.handleTriggerKey(event);
    this.onPanelKeydown = (event) => this.handlePanelKey(event);
    this.onPanelClick = (event) => this.handlePanelClick(event);
    this.onPanelMove = (event) => this.handlePanelMove(event);
    this.onPanelFocusOut = (event) => this.handlePanelFocusOut(event);
    this.onNativeChoice = (event) => this.handleNativeChoice(event);
    this.onLabelClick = (event) => this.handleLabelClick(event);

    this.trigger.addEventListener("click", this.onTriggerClick);
    this.trigger.addEventListener("keydown", this.onTriggerKeydown);
    this.panel.addEventListener("keydown", this.onPanelKeydown);
    this.panel.addEventListener("click", this.onPanelClick);
    this.panel.addEventListener("pointermove", this.onPanelMove);
    this.panel.addEventListener("focusout", this.onPanelFocusOut);
    this.native.addEventListener("input", this.onNativeChoice);
    this.native.addEventListener("change", this.onNativeChoice);
    this.el.addEventListener("click", this.onLabelClick);
  },

  updated() {
    if (!floatingPanelsSupported()) this.el.dataset.selectForceNative = "";

    this.syncFromServer();

    this.trigger.setAttribute("aria-expanded", this.open ? "true" : "false");

    if (this.open) {
      this.rebuildOpenList();
      this.open.reposition();
    }
  },

  destroyed() {
    this.close(false);
  },

  nativeActive() {
    return getComputedStyle(this.native).display !== "none";
  },

  // A patch writes the server's value back over the hidden input. If the
  // server has moved on, its value stands. If not, this is a re-render for
  // some other reason (or a form that never echoes this field), and the
  // visitor's choice is kept, as a focused native select keeps its own.
  syncFromServer() {
    const rendered = this.valueInput.value;

    if (rendered !== this.serverValue) {
      this.serverValue = rendered;
      this.chosenValue = null;
    } else if (this.chosenValue !== null && this.chosenValue !== rendered) {
      this.writeValue(this.chosenValue);
    }
  },

  writeValue(value) {
    this.valueInput.value = value;
    this.native.value = value;

    const option = Array.from(this.native.options).find((o) => o.value === value);

    if (option) {
      this.valueText.textContent = option.text;
      this.valueText.classList.toggle("select-value--placeholder", value === "");
    }
  },

  commit(value) {
    if (value === this.valueInput.value) return;

    this.chosenValue = value;
    this.writeValue(value);
    this.valueInput.dispatchEvent(new Event("input", { bubbles: true }));
  },

  // The native select changing under the visitor (it answers on the hidden
  // input instead) must not reach LiveView's own form listeners, which would
  // push a change carrying the old value.
  handleNativeChoice(event) {
    event.stopPropagation();
    this.commit(this.native.value);
  },

  rebuildOpenList() {
    const activeValue = this.options[this.activeIndex]?.value;

    this.buildOptions();

    const index = this.options.findIndex((o) => o.value === activeValue);

    if (index >= 0) this.activeIndex = index;
    this.renderActive();
  },

  buildOptions() {
    this.options = [];
    this.panel.replaceChildren();

    const groups = new Map();

    Array.from(this.native.options).forEach((option, index) => {
      const entry = {
        value: option.value,
        label: option.text,
        disabled: option.disabled,
        id: `${this.panel.id}-option-${index}`,
      };

      this.options.push(entry);
      entry.el = this.optionElement(entry);

      const optgroup = option.parentElement.tagName === "OPTGROUP" ? option.parentElement : null;

      if (optgroup && !groups.has(optgroup)) {
        const group = document.createElement("div");
        const heading = document.createElement("div");

        group.setAttribute("role", "group");
        group.setAttribute("aria-label", optgroup.label);
        heading.className = "select-group-label";
        heading.setAttribute("aria-hidden", "true");
        heading.textContent = optgroup.label;
        group.appendChild(heading);
        groups.set(optgroup, group);
        this.panel.appendChild(group);
      }

      (optgroup ? groups.get(optgroup) : this.panel).appendChild(entry.el);
    });

    this.activeIndex = this.options.findIndex((o) => o.value === this.valueInput.value);
    if (this.activeIndex < 0) this.activeIndex = this.nextEnabled(-1, 1);
  },

  optionElement({ value, label, disabled, id }) {
    const el = document.createElement("div");

    el.id = id;
    el.setAttribute("role", "option");
    el.setAttribute("aria-selected", value === this.valueInput.value ? "true" : "false");
    if (disabled) el.setAttribute("aria-disabled", "true");
    el.className = value === "" ? "select-option select-option--placeholder" : "select-option";
    el.textContent = label;
    return el;
  },

  show(initialBuffer = "") {
    if (this.open || this.trigger.disabled) return;

    this.buildOptions();
    this.open = openFloatingPanel({
      panel: this.panel,
      anchor: this.trigger,
      onDismiss: () => this.afterClose(true),
    });
    this.trigger.setAttribute("aria-expanded", "true");
    this.panel.focus({ preventScroll: true });
    this.renderActive();

    if (initialBuffer !== "") this.pushTyped(initialBuffer);
  },

  close(returnFocus) {
    if (!this.open) return;

    this.open.close();
    this.afterClose(returnFocus);
  },

  afterClose(returnFocus) {
    this.open = null;
    this.trigger.setAttribute("aria-expanded", "false");
    this.panel.removeAttribute("aria-activedescendant");
    this.typed = "";

    if (returnFocus && this.el.isConnected) this.trigger.focus({ preventScroll: true });
  },

  choose(index) {
    const option = this.options[index];
    if (!option || option.disabled) return;

    this.close(true);
    this.commit(option.value);
  },

  nextEnabled(from, direction) {
    let index = from + direction;

    while (index >= 0 && index < this.options.length) {
      if (!this.options[index].disabled) return index;
      index += direction;
    }

    return from;
  },

  moveActive(index) {
    this.activeIndex = index;
    this.renderActive();
  },

  renderActive() {
    this.options.forEach(({ el }, index) => {
      el.classList.toggle("is-active", index === this.activeIndex);
    });

    const active = this.options[this.activeIndex]?.el;

    if (active) {
      this.panel.setAttribute("aria-activedescendant", active.id);
      active.scrollIntoView({ block: "nearest" });
    } else {
      this.panel.removeAttribute("aria-activedescendant");
    }
  },

  pushTyped(char) {
    const now = Date.now();

    if (now - this.typedAt > TYPE_AHEAD_RESET_MS) this.typed = "";
    this.typedAt = now;
    this.typed += char.toLowerCase();

    const index = typeAheadIndex(this.options, this.typed, this.activeIndex);

    if (index >= 0) this.moveActive(index);
  },

  handleTriggerKey(event) {
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      this.show();
    } else if (this.isPrintable(event) && event.key !== " ") {
      event.preventDefault();
      this.show(event.key);
    }
  },

  isPrintable(event) {
    return event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey;
  },

  handlePanelKey(event) {
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        this.moveActive(this.nextEnabled(this.activeIndex, 1));
        break;
      case "ArrowUp":
        event.preventDefault();
        this.moveActive(this.nextEnabled(this.activeIndex, -1));
        break;
      case "Home":
        event.preventDefault();
        this.moveActive(this.nextEnabled(-1, 1));
        break;
      case "End":
        event.preventDefault();
        this.moveActive(this.nextEnabled(this.options.length, -1));
        break;
      case "PageDown":
        event.preventDefault();
        this.movePage(1);
        break;
      case "PageUp":
        event.preventDefault();
        this.movePage(-1);
        break;
      case "Enter":
        event.preventDefault();
        this.choose(this.activeIndex);
        break;
      case " ":
        event.preventDefault();

        // A space inside a type-ahead word is part of the word.
        if (this.typed !== "" && Date.now() - this.typedAt <= TYPE_AHEAD_RESET_MS) {
          this.pushTyped(" ");
        } else {
          this.choose(this.activeIndex);
        }
        break;
      case "Tab":
        // As a native select: commit the highlighted option and move on, the
        // browser carrying on from the trigger once focus is back on it.
        this.choose(this.activeIndex);
        break;
      default:
        if (this.isPrintable(event)) {
          event.preventDefault();
          this.pushTyped(event.key);
        }
    }
  },

  movePage(direction) {
    let index = this.activeIndex;

    for (let step = 0; step < PAGE_STEP; step += 1) index = this.nextEnabled(index, direction);

    this.moveActive(index);
  },

  optionIndex(target) {
    const option = target instanceof Element ? target.closest("[role='option']") : null;

    return option ? this.options.findIndex(({ el }) => el === option) : -1;
  },

  handlePanelClick(event) {
    const index = this.optionIndex(event.target);

    if (index >= 0) this.choose(index);
  },

  handlePanelMove(event) {
    const index = this.optionIndex(event.target);

    if (index >= 0 && index !== this.activeIndex && !this.options[index].disabled) {
      this.moveActive(index);
    }
  },

  // Focus leaving the list closes it (a click elsewhere is the pointerdown's
  // business); a tab away from the window is not leaving it.
  handlePanelFocusOut(event) {
    if (event.relatedTarget && !this.panel.contains(event.relatedTarget)) this.close(false);
  },

  // A label pointing at the (visually absent) native select would do nothing
  // on a mouse-driven page, and on a button would open the list: focus is what
  // a click on a label means.
  handleLabelClick(event) {
    if (!event.target.closest("label")) return;

    event.preventDefault();
    (this.nativeActive() ? this.native : this.trigger).focus();
  },
};
