/**
 * Tests for `<.select>`'s behaviour (hooks/select.js) and the placement of its
 * panel (floating_panel.js). The real browser checks live in the Wallaby
 * suite; these cover the keyboard model and the placement arithmetic.
 */

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { Select, typeAheadIndex } from "../hooks/select";
import { computePlacement } from "../floating_panel";

const openHooks = [];

function buildField() {
  document.body.innerHTML = `
    <form id="host">
      <div id="f-field">
        <label for="f">Pick</label>
        <input type="hidden" data-select-value name="f" value="2" />
        <button type="button" data-select-trigger id="f-trigger" aria-expanded="false">
          <span data-select-text>Two</span>
        </button>
        <select id="f" data-select-native style="display: none">
          <option value="1">Apple</option>
          <option value="2" selected>Banana</option>
          <option value="3" disabled>Cherry</option>
          <option value="4">Date</option>
          <option value="5">Dragon fruit</option>
        </select>
        <div id="f-panel" data-select-panel tabindex="-1"></div>
      </div>
    </form>`;

  const el = document.querySelector("#f-field");
  const hook = Object.assign(Object.create(Select), { el });

  hook.mounted();
  openHooks.push(hook);
  return hook;
}

function press(target, key) {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
}

describe("computePlacement", () => {
  const viewport = { width: 400, height: 800 };
  const anchor = { top: 100, bottom: 140, left: 16, width: 200 };

  test("opens below when the panel fits there", () => {
    const placed = computePlacement(anchor, { width: 200, height: 300 }, viewport);

    expect(placed.placement).toBe("below");
    expect(placed.top).toBe(144);
    expect(placed.maxHeight).toBe(300);
  });

  test("flips above when there is more room above", () => {
    const low = { top: 700, bottom: 740, left: 16, width: 200 };
    const placed = computePlacement(low, { width: 200, height: 300 }, viewport);

    expect(placed.placement).toBe("above");
    expect(placed.top).toBe(396);
  });

  test("scrolls within the larger side when neither holds it all", () => {
    const placed = computePlacement(
      { top: 300, bottom: 340, left: 16, width: 200 },
      { width: 200, height: 1000 },
      viewport
    );

    expect(placed.placement).toBe("below");
    expect(placed.maxHeight).toBe(448);
  });

  test("keeps a wide panel inside a phone-width viewport", () => {
    const placed = computePlacement(
      { top: 100, bottom: 140, left: 300, width: 80 },
      { width: 304, height: 200 },
      { width: 320, height: 600 }
    );

    expect(placed.left).toBe(8);
  });

  test("covers the anchor rather than draw a sliver in a short viewport", () => {
    const placed = computePlacement(
      { top: 40, bottom: 80, left: 16, width: 200 },
      { width: 200, height: 400 },
      { width: 320, height: 180 }
    );

    expect(placed.placement).toBe("cover");
    expect(placed.top).toBe(8);
    expect(placed.maxHeight).toBe(164);
  });
});

describe("typeAheadIndex", () => {
  const options = [
    { label: "Apple", disabled: false },
    { label: "Banana", disabled: false },
    { label: "Cherry", disabled: true },
    { label: "Date", disabled: false },
    { label: "Dragon fruit", disabled: false },
  ];

  test("matches a prefix from the current option", () => {
    expect(typeAheadIndex(options, "dr", 0)).toBe(4);
  });

  test("cycles through options on a repeated character", () => {
    expect(typeAheadIndex(options, "d", 3)).toBe(4);
    expect(typeAheadIndex(options, "dd", 4)).toBe(3);
  });

  test("skips a disabled option", () => {
    expect(typeAheadIndex(options, "c", 0)).toBe(-1);
  });
});

describe("the Select hook", () => {
  let inputs;
  let recordInput;

  beforeEach(() => {
    HTMLElement.prototype.showPopover = vi.fn(function () {
      this.dataset.popoverOpen = "";
    });
    HTMLElement.prototype.hidePopover = vi.fn(function () {
      delete this.dataset.popoverOpen;
    });
    HTMLElement.prototype.scrollIntoView = vi.fn();
    Element.prototype.matches = (function (original) {
      return function (selector) {
        if (selector === ":popover-open") return "popoverOpen" in this.dataset;
        return original.call(this, selector);
      };
    })(Element.prototype.matches);
    inputs = [];
    recordInput = (event) => inputs.push(event.target.name);
    window.addEventListener("input", recordInput);
  });

  afterEach(() => {
    openHooks.splice(0).forEach((hook) => hook.close(false));
    window.removeEventListener("input", recordInput);
    delete HTMLElement.prototype.showPopover;
    delete HTMLElement.prototype.hidePopover;
    document.body.innerHTML = "";
  });

  test("opens on click, focuses the list and marks the selected option active", () => {
    const hook = buildField();
    hook.trigger.click();

    expect(hook.trigger.getAttribute("aria-expanded")).toBe("true");
    expect(document.activeElement).toBe(hook.panel);
    expect(hook.options[hook.activeIndex].value).toBe("2");
    expect(hook.panel.getAttribute("aria-activedescendant")).toBe(hook.options[1].id);
  });

  test("arrows skip disabled options and Enter commits through the hidden input", () => {
    const hook = buildField();
    hook.trigger.click();

    press(hook.panel, "ArrowDown");
    expect(hook.options[hook.activeIndex].value).toBe("4");

    press(hook.panel, "Enter");

    expect(hook.valueInput.value).toBe("4");
    expect(hook.valueText.textContent).toBe("Date");
    expect(inputs).toEqual(["f"]);
    expect(hook.open).toBeNull();
    expect(document.activeElement).toBe(hook.trigger);
  });

  test("Escape closes without changing the value", () => {
    const hook = buildField();
    hook.trigger.click();
    press(hook.panel, "ArrowDown");
    press(document.body, "Escape");

    expect(hook.open).toBeNull();
    expect(hook.valueInput.value).toBe("2");
    expect(inputs).toEqual([]);
  });

  test("a printable key on the closed button opens the list and jumps to a match", () => {
    const hook = buildField();

    press(hook.trigger, "d");

    expect(hook.open).not.toBeNull();
    expect(hook.options[hook.activeIndex].value).toBe("4");
  });

  test("the native select's choice commits once and stops LiveView seeing it twice", () => {
    const hook = buildField();

    hook.native.value = "5";
    hook.native.dispatchEvent(new Event("input", { bubbles: true }));
    hook.native.dispatchEvent(new Event("change", { bubbles: true }));

    expect(hook.valueInput.value).toBe("5");
    expect(inputs).toEqual(["f"]);
  });

  test("keeps a choice the server has not echoed through an unrelated patch", () => {
    const hook = buildField();

    hook.commit("4");
    hook.valueInput.value = "2"; // a patch writing the server's value back
    hook.updated();

    expect(hook.valueInput.value).toBe("4");
  });

  test("takes the server's value once it changes", () => {
    const hook = buildField();

    hook.commit("4");
    hook.valueInput.value = "1";
    hook.updated();

    expect(hook.valueInput.value).toBe("1");
    expect(hook.chosenValue).toBeNull();
  });

  test("pressing the button of an open list closes it and it stays closed", () => {
    const hook = buildField();
    hook.trigger.click();

    // A press moves focus to the button first, then clicks it.
    hook.panel.dispatchEvent(new FocusEvent("focusout", { relatedTarget: hook.trigger }));
    expect(hook.open).not.toBeNull();

    hook.trigger.click();
    expect(hook.open).toBeNull();
    expect(hook.trigger.getAttribute("aria-expanded")).toBe("false");
  });

  test("focus moving elsewhere closes the list", () => {
    const hook = buildField();
    const elsewhere = document.createElement("button");
    document.body.appendChild(elsewhere);
    hook.trigger.click();

    hook.panel.dispatchEvent(new FocusEvent("focusout", { relatedTarget: elsewhere }));

    expect(hook.open).toBeNull();
  });

  test("a button out of view opens nothing and leaves no listeners behind", () => {
    const hook = buildField();
    hook.trigger.getBoundingClientRect = () => ({ top: -100, bottom: -60, left: 0, width: 100 });

    hook.show();

    expect(hook.open).toBeNull();
    expect(hook.trigger.getAttribute("aria-expanded")).toBe("false");

    const escape = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
    document.body.dispatchEvent(escape);
    expect(escape.defaultPrevented).toBe(false);
  });

  test("a click on the label focuses the button rather than opening it", () => {
    const hook = buildField();

    hook.el.querySelector("label").click();

    expect(hook.open).toBeNull();
    expect(document.activeElement).toBe(hook.trigger);
  });

  test("builds an option group under its heading, still reachable by arrow keys", () => {
    const hook = buildField();

    hook.native.innerHTML =
      '<optgroup label="Places"><option value="h">Hall</option></optgroup><option value="z">Zoom</option>';
    hook.valueInput.value = "h";
    hook.trigger.click();

    expect(hook.panel.querySelector("[role='group']").getAttribute("aria-label")).toBe("Places");
    expect(hook.options.map((o) => o.value)).toEqual(["h", "z"]);

    press(hook.panel, "ArrowDown");

    expect(hook.options[hook.activeIndex].value).toBe("z");
  });
});
