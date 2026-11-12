/**
 * Tests for the date and time pickers: the parsing and formatting
 * (date_time_format.js) and the hook's keyboard, focus and value handling.
 * The real browser checks live in the Wallaby suite.
 */

import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import {
  addMonths,
  formatDate,
  formatTime,
  monthMatrix,
  parseDate,
  parseTime,
} from "../date_time_format";
import { DateTimePicker } from "../hooks/date_time_picker";

const config = {
  locale: "en",
  weekStart: 1,
  datePattern: "{d} {m} {y}",
  shortMonths: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  longMonths: [
    "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December",
  ],
  monthHeadings: [
    "January {y}", "February {y}", "March {y}", "April {y}", "May {y}", "June {y}",
    "July {y}", "August {y}", "September {y}", "October {y}", "November {y}", "December {y}",
  ],
  timeFormat: "24h",
  timeOptions: [
    ["00:00", "00:00"],
    ["09:00", "09:00"],
    ["09:15", "09:15"],
    ["14:30", "14:30"],
  ],
};

describe("parseDate", () => {
  const today = new Date(2026, 10, 14);

  test("reads the field's own short format back", () => {
    expect(parseDate("5 Feb 2026", config, today)).toBe("2026-02-05");
  });

  test("reads ISO, day-first numbers and a two-digit year", () => {
    expect(parseDate("2026-02-05", config, today)).toBe("2026-02-05");
    expect(parseDate("05/02/2026", config, today)).toBe("2026-02-05");
    expect(parseDate("5.2.26", config, today)).toBe("2026-02-05");
  });

  test("reads a two-digit year as the nearest one no more than 20 years ahead", () => {
    expect(parseDate("1/1/85", config, today)).toBe("1985-01-01");
    expect(parseDate("1/1/46", config, today)).toBe("2046-01-01");
    expect(parseDate("1/1/47", config, today)).toBe("1947-01-01");
  });

  test("takes a full month name, with words between the numbers, and no year", () => {
    expect(parseDate("5 de February de 2026", config, today)).toBe("2026-02-05");
    expect(parseDate("5 feb", config, today)).toBe("2026-02-05");
  });

  test("reads a cleared field as cleared, and nonsense as unreadable", () => {
    expect(parseDate("   ", config, today)).toBe("");
    expect(parseDate("31/02/2026", config, today)).toBeNull();
    expect(parseDate("soon", config, today)).toBeNull();
  });
});

describe("parseTime", () => {
  test("reads either clock whatever the field shows", () => {
    expect(parseTime("14:30")).toBe("14:30");
    expect(parseTime("1430")).toBe("14:30");
    expect(parseTime("2.30 pm")).toBe("14:30");
    expect(parseTime("2pm")).toBe("14:00");
    expect(parseTime("12 am")).toBe("00:00");
    expect(parseTime("12:30 PM")).toBe("12:30");
  });

  test("clears on empty and refuses an impossible time", () => {
    expect(parseTime("")).toBe("");
    expect(parseTime("25:00")).toBeNull();
    expect(parseTime("12:75")).toBeNull();
  });
});

describe("formatting", () => {
  test("a date as the server writes it", () => {
    expect(formatDate("2026-02-05", config)).toBe("5 Feb 2026");
    expect(formatDate("", config)).toBe("");
  });

  test("a time in the chosen clock", () => {
    expect(formatTime("14:30", "12h")).toBe("2:30 PM");
    expect(formatTime("00:05", "12h")).toBe("12:05 AM");
    expect(formatTime("14:30", "24h")).toBe("14:30");
  });

  test("a month back from the 31st stops at the month's last day", () => {
    expect(addMonths("2026-03-31", -1)).toBe("2026-02-28");
  });
});

describe("monthMatrix", () => {
  test("starts on the viewer's week start and spans six weeks", () => {
    const monday = monthMatrix(2026, 11, 1);
    const sunday = monthMatrix(2026, 11, 0);

    expect(monday).toHaveLength(42);
    expect(monday[0]).toBe("2026-10-26");
    expect(sunday[0]).toBe("2026-11-01");
  });
});

const openHooks = [];

function markup(kind, value, attrs = "") {
  const part = (name) => `
    <div data-picker-part="${name}">
      <input type="text" id="p-${name}" data-picker-text />
      <button type="button" data-picker-trigger aria-expanded="false"></button>
      <div id="p-${name}-panel" data-picker-panel tabindex="-1">
        <button data-picker-prev></button>
        <div data-picker-month></div>
        <button data-picker-next></button>
        <table><tbody data-picker-days></tbody></table>
      </div>
    </div>`;

  const parts = kind === "datetime" ? ["date", "time"] : [kind];

  return `
      <input type="hidden" data-picker-value name="v" value="${value}" />
      ${parts.map(part).join("")}
      <input id="p-native" data-picker-native style="display: none" ${attrs} />`;
}

function field(kind, value, attrs = "", extraConfig = {}) {
  document.body.innerHTML = `
    <form id="host" phx-submit="save">
      <div id="p-field" data-picker-kind="${kind}" data-picker-config='${JSON.stringify({ ...config, ...extraConfig })}'>
        ${markup(kind, value, attrs)}
      </div>
    </form>`;

  const el = document.querySelector("#p-field");
  const hook = Object.assign(Object.create(DateTimePicker), { el });

  hook.mounted();
  openHooks.push(hook);
  return hook;
}

function press(target, key, options = {}) {
  target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...options }));
}

function listenInput() {
  const seen = [];
  document.querySelector("[data-picker-value]").addEventListener("input", (e) => seen.push(e.target.value));
  return seen;
}

const part = (hook, name = "date") => hook.parts.find((p) => p.name === name);

describe("the DateTimePicker hook", () => {
  beforeEach(() => {
    HTMLElement.prototype.showPopover = vi.fn(function show() {
      this.dataset.popoverOpen = "";
    });
    HTMLElement.prototype.hidePopover = vi.fn(function hide() {
      delete this.dataset.popoverOpen;
    });

    const matches = Element.prototype.matches;

    vi.spyOn(Element.prototype, "matches").mockImplementation(function patched(selector) {
      if (selector === ":popover-open") return "popoverOpen" in this.dataset;
      return matches.call(this, selector);
    });
    Element.prototype.scrollIntoView = vi.fn();
    // jsdom has no form submission; Enter's submit is asserted where it matters.
    vi.spyOn(HTMLFormElement.prototype, "requestSubmit").mockImplementation(() => {});
  });

  afterEach(() => {
    openHooks.splice(0).forEach((hook) => hook.destroyed());
    delete HTMLElement.prototype.showPopover;
    delete HTMLElement.prototype.hidePopover;
    vi.restoreAllMocks();
  });

  test("a press on a day posts ISO through the hidden input and closes", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);
    const seen = listenInput();

    date.trigger.click();
    expect(date.panel.dataset.popoverOpen).toBe("");
    expect(date.panel.querySelector("[data-picker-month]").textContent).toBe("November 2026");

    date.panel.querySelector('[data-date="2026-11-20"]').click();

    expect(seen).toEqual(["2026-11-20"]);
    expect(date.text.value).toBe("20 Nov 2026");
    expect(date.open).toBeNull();
    expect(document.activeElement).toBe(date.trigger);
  });

  test("arrows move the day and Page keys the month, and Enter chooses", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);
    const seen = listenInput();

    date.trigger.click();
    expect(document.activeElement.dataset.date).toBe("2026-11-14");

    press(document.activeElement, "ArrowRight");
    expect(document.activeElement.dataset.date).toBe("2026-11-15");

    press(document.activeElement, "ArrowDown");
    expect(document.activeElement.dataset.date).toBe("2026-11-22");

    press(document.activeElement, "PageDown");
    expect(document.activeElement.dataset.date).toBe("2026-12-22");
    expect(date.panel.querySelector("[data-picker-month]").textContent).toBe("December 2026");

    press(document.activeElement, "PageUp", { shiftKey: true });
    expect(document.activeElement.dataset.date).toBe("2025-12-22");

    press(document.activeElement, "Enter");
    expect(seen).toEqual(["2025-12-22"]);
  });

  test("Home and End go to the ends of the viewer's week", () => {
    const hook = field("date", "2026-11-11");
    const date = part(hook);

    date.trigger.click();
    press(document.activeElement, "Home");
    expect(document.activeElement.dataset.date).toBe("2026-11-09");
    press(document.activeElement, "End");
    expect(document.activeElement.dataset.date).toBe("2026-11-15");
  });

  test("Tab stays inside the dialog", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);

    date.trigger.click();
    press(document.activeElement, "Tab");

    expect(date.panel.contains(document.activeElement)).toBe(true);
  });

  test("Escape closes the panel, is kept from the page, and leaves the value", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);
    const onPage = vi.fn();

    window.addEventListener("keydown", onPage);
    date.trigger.click();
    press(document.activeElement, "Escape");
    window.removeEventListener("keydown", onPage);

    expect(date.open).toBeNull();
    expect(onPage).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(date.trigger);
    expect(hook.valueInput.value).toBe("2026-11-14");
  });

  test("pressing the button of an open panel closes it and it stays closed", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);

    date.trigger.click();
    document.activeElement.dispatchEvent(
      new FocusEvent("focusout", { relatedTarget: date.trigger, bubbles: true })
    );
    expect(date.open).not.toBeNull();

    date.trigger.click();
    expect(date.open).toBeNull();
    expect(date.panel.dataset.popoverOpen).toBeUndefined();
  });

  test("a field out of view opens nothing and leaves no handle or listeners", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);
    const removed = vi.spyOn(document, "removeEventListener");

    date.root.getBoundingClientRect = () => ({ top: 5000, bottom: 5040, left: 0, width: 200 });
    date.trigger.click();

    expect(date.open).toBeNull();
    expect(date.panel.dataset.popoverOpen).toBeUndefined();
    expect(removed).toHaveBeenCalledWith("keydown", expect.any(Function), true);
    expect(removed).toHaveBeenCalledWith("pointerdown", expect.any(Function), true);
  });

  test("a day outside min and max cannot be chosen", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);
    const seen = listenInput();

    hook.native.min = "2026-11-10";
    date.trigger.click();
    date.panel.querySelector('[data-date="2026-11-09"]').click();

    expect(seen).toEqual([]);
    expect(date.open).not.toBeNull();
  });

  test("typed text commits on change and is rewritten in the field's format", () => {
    const hook = field("date", "");
    const date = part(hook);
    const seen = listenInput();

    date.text.value = "14/11/2026";
    date.text.dispatchEvent(new Event("change", { bubbles: true }));

    expect(seen).toEqual(["2026-11-14"]);
    expect(date.text.value).toBe("14 Nov 2026");
  });

  test("Enter writes the reading back into the focused field", () => {
    const hook = field("date", "");
    const date = part(hook);

    date.text.focus();
    date.text.value = "14/11/26";
    press(date.text, "Enter");

    expect(document.activeElement).toBe(date.text);
    expect(date.text.value).toBe("14 Nov 2026");
  });

  test("typing nonsense goes back to the last good value", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);
    const seen = listenInput();

    date.text.value = "someday";
    date.text.dispatchEvent(new Event("change", { bubbles: true }));

    expect(seen).toEqual([]);
    expect(date.text.value).toBe("14 Nov 2026");
  });

  test("a typed field's own events never reach the form's listeners", () => {
    const hook = field("date", "2026-11-14");
    const onForm = vi.fn();

    document.querySelector("#host").addEventListener("input", onForm);
    part(hook).text.dispatchEvent(new Event("input", { bubbles: true }));

    expect(onForm).not.toHaveBeenCalled();
  });

  test("Enter takes the typed value and submits the form explicitly", () => {
    const hook = field("date", "");
    const date = part(hook);
    const seen = listenInput();
    const form = document.querySelector("#host");
    const requestSubmit = vi.fn();

    form.requestSubmit = requestSubmit;
    date.text.value = "1/2/2026";

    const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });

    date.text.dispatchEvent(event);

    expect(seen).toEqual(["2026-02-01"]);
    expect(event.defaultPrevented).toBe(true);
    expect(requestSubmit).toHaveBeenCalledTimes(1);
  });

  test("Enter takes the typed value, and leaves a form with no submit alone", () => {
    const hook = field("date", "");
    const date = part(hook);
    const seen = listenInput();

    const form = document.querySelector("#host");
    const requestSubmit = vi.fn();

    form.removeAttribute("phx-submit");
    form.requestSubmit = requestSubmit;
    date.text.value = "1/2/2026";

    const event = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });

    date.text.dispatchEvent(event);

    expect(seen).toEqual(["2026-02-01"]);
    expect(event.defaultPrevented).toBe(true);
    expect(requestSubmit).not.toHaveBeenCalled();
  });

  test("the calendar opens on, and marks, the page's today rather than the device's", () => {
    const hook = field("date", "", "", { today: "2030-05-20" });
    const date = part(hook);

    date.trigger.click();

    expect(date.panel.querySelector("[data-picker-month]").textContent).toBe("May 2030");
    expect(date.panel.querySelector('[aria-current="date"]').dataset.date).toBe("2030-05-20");
    expect(document.activeElement.dataset.date).toBe("2030-05-20");
  });

  test("the time list posts HH:MM and marks the current time", () => {
    const hook = field("time", "09:00");
    const time = part(hook, "time");
    const seen = listenInput();

    time.trigger.click();
    expect(time.panel.getAttribute("aria-activedescendant")).toBe(time.options[1].el.id);

    press(time.panel, "ArrowDown");
    press(time.panel, "Enter");

    expect(seen).toEqual(["09:15"]);
    expect(time.text.value).toBe("09:15");
  });

  test("a combined field posts the half it has, so the server can say what is missing", () => {
    const hook = field("datetime", "");
    const seen = listenInput();

    hook.setPart("date", "2026-11-14");

    expect(seen).toEqual(["2026-11-14"]);
    expect(part(hook, "time").text.value).toBe("");

    hook.setPart("time", "10:15");

    expect(seen).toEqual(["2026-11-14", "2026-11-14T10:15"]);
  });

  test("composeValue tells blank, a date alone, a time alone and both apart", () => {
    const hook = field("datetime", "");

    expect(hook.composeValue()).toBe("");

    hook.state = { date: "2026-11-14", time: "" };
    expect(hook.composeValue()).toBe("2026-11-14");

    hook.state = { date: "", time: "10:15" };
    expect(hook.composeValue()).toBe("T10:15");

    hook.state = { date: "2026-11-14", time: "10:15" };
    expect(hook.composeValue()).toBe("2026-11-14T10:15");
  });

  test("a half-filled value from the server shows the half it has", () => {
    const hook = field("datetime", "T10:15");

    expect(part(hook, "date").text.value).toBe("");
    expect(hook.state).toEqual({ date: "", time: "10:15" });
  });

  test("an empty time list opens on 09:00 without choosing it, and Tab leaves it unchosen", () => {
    const hook = field("time", "");
    const time = part(hook, "time");
    const seen = listenInput();

    time.trigger.click();
    expect(time.panel.getAttribute("aria-activedescendant")).toBe(time.options[1].el.id);

    press(time.panel, "Tab");

    expect(seen).toEqual([]);
    expect(time.open).toBeNull();
    expect(document.activeElement).toBe(time.trigger);
  });

  test("Tab takes a time the visitor moved to with the keys", () => {
    const hook = field("time", "");
    const time = part(hook, "time");
    const seen = listenInput();

    time.trigger.click();
    press(time.panel, "ArrowDown");
    press(time.panel, "Tab");

    expect(seen).toEqual(["09:15"]);
  });

  test("times outside min and max are marked and skipped", () => {
    const hook = field("time", "", 'min="09:00" max="09:15"');
    const time = part(hook, "time");
    const seen = listenInput();

    time.trigger.click();

    expect(time.options[0].el.getAttribute("aria-disabled")).toBe("true");
    expect(time.options[3].el.getAttribute("aria-disabled")).toBe("true");

    press(time.panel, "Home");
    expect(time.panel.getAttribute("aria-activedescendant")).toBe(time.options[1].el.id);

    press(time.panel, "End");
    expect(time.panel.getAttribute("aria-activedescendant")).toBe(time.options[2].el.id);

    time.options[3].el.click();
    expect(seen).toEqual([]);
  });

  test("with no value, the grid opens on min when today is before it", () => {
    const hook = field("date", "", 'min="2099-03-10"');
    const date = part(hook);

    date.trigger.click();

    expect(document.activeElement.dataset.date).toBe("2099-03-10");
  });

  test("a field that comes back as another kind is built again", () => {
    const hook = field("date", "");

    hook.el.dataset.pickerKind = "time";
    hook.el.innerHTML = markup("time", "");
    hook.updated();

    const time = part(hook, "time");
    const seen = listenInput();

    expect(hook.parts.map((p) => p.name)).toEqual(["time"]);

    time.trigger.click();
    expect(time.panel.querySelector("[role='option']")).not.toBeNull();
    press(time.panel, "Enter");

    expect(seen).toEqual(["09:00"]);
  });

  test("autofocus goes to the native control when it is the one on show", () => {
    document.body.innerHTML = `
      <div id="p-field" data-picker-kind="date" data-picker-config='${JSON.stringify(config)}'>
        <input type="hidden" data-picker-value name="v" value="" />
        <div data-picker-part="date">
          <input type="text" data-picker-text autofocus />
          <button type="button" data-picker-trigger></button>
          <div data-picker-panel></div>
        </div>
        <input id="p-native" data-picker-native />
      </div>`;

    const hook = Object.assign(Object.create(DateTimePicker), {
      el: document.querySelector("#p-field"),
    });

    hook.mounted();
    openHooks.push(hook);

    expect(document.activeElement.id).toBe("p-native");
  });

  test("the native control's choice commits once and stops LiveView seeing it", () => {
    const hook = field("date", "");
    const onForm = vi.fn();

    document.querySelector("#host").addEventListener("change", onForm);
    hook.native.value = "2026-11-14";
    hook.native.dispatchEvent(new Event("change", { bubbles: true }));

    expect(onForm).not.toHaveBeenCalled();
    expect(hook.valueInput.value).toBe("2026-11-14");
    expect(part(hook).text.value).toBe("14 Nov 2026");
  });

  test("keeps a choice the server has not echoed through an unrelated patch", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);

    hook.setPart("date", "2026-11-20");
    hook.valueInput.value = "2026-11-14";
    date.text.value = "14 Nov 2026";
    hook.updated();

    expect(hook.valueInput.value).toBe("2026-11-20");
    expect(date.text.value).toBe("20 Nov 2026");
  });

  test("takes the server's value once it changes", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);

    hook.setPart("date", "2026-11-20");
    hook.valueInput.value = "2026-12-01";
    hook.updated();

    expect(hook.valueInput.value).toBe("2026-12-01");
    expect(date.text.value).toBe("1 Dec 2026");
  });

  test("a patch does not overwrite what is being typed", () => {
    const hook = field("date", "2026-11-14");
    const date = part(hook);

    date.text.focus();
    date.text.value = "1/2/20";
    hook.updated();

    expect(date.text.value).toBe("1/2/20");
  });

  test("marks the field native when the Popover API is missing", () => {
    delete HTMLElement.prototype.showPopover;

    const hook = field("date", "");

    expect("pickerForceNative" in hook.el.dataset).toBe(true);
  });

  test("a click on the label focuses the typed field", () => {
    const hook = field("date", "");
    const date = part(hook);
    const label = document.createElement("label");

    hook.el.appendChild(label);
    hook.native.style.display = "none";
    label.click();

    expect(document.activeElement).toBe(date.text);
  });
});
