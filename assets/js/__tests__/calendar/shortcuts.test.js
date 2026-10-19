/**
 * Tests for calendar/shortcuts.js: the guard every single-key shortcut on
 * the calendar passes, and the Ctrl K, digit and platform helpers.
 */
import { afterEach, describe, expect, test } from "vitest";
import { MODALS, digitOf, isCommandKey, isMac, plainKeyAllowed } from "../../calendar/shortcuts.js";

const hook = (extra = {}) => ({ settings: {}, ...extra });
const key = (k, extra = {}) => ({ key: k, target: document.body, ...extra });
const add = (html) => {
  document.body.insertAdjacentHTML("beforeend", html);
  return document.body.lastElementChild;
};

afterEach(() => {
  document.body.innerHTML = "";
});

describe("plainKeyAllowed", () => {
  test("lets a plain key through with focus on the page", () => {
    expect(plainKeyAllowed(key("j"), hook())).toBe(true);
  });

  test.each([
    ["a held key", { repeat: true }],
    ["Ctrl", { ctrlKey: true }],
    ["Cmd", { metaKey: true }],
    ["Alt", { altKey: true }],
    ["an IME composing", { isComposing: true }],
    ["a key another handler took", { defaultPrevented: true }],
  ])("refuses %s", (_name, extra) => {
    expect(plainKeyAllowed(key("j", extra), hook())).toBe(false);
  });

  test("refuses before the first settings arrive", () => {
    expect(plainKeyAllowed(key("j"), { settings: null })).toBe(false);
  });

  test.each(["drag", "createDrag", "moving", "quick"])("refuses while %s is live", (state) => {
    expect(plainKeyAllowed(key("j"), hook({ [state]: {} }))).toBe(false);
  });

  test.each([
    ["a text input", '<input type="text">'],
    ["a textarea", "<textarea></textarea>"],
    ["a select", "<select></select>"],
    ["an editable region", '<div contenteditable="true"></div>'],
  ])("refuses while typing in %s", (_name, html) => {
    expect(plainKeyAllowed(key("j", { target: add(html) }), hook())).toBe(false);
  });

  test("refuses inside a dialog", () => {
    const button = add('<div role="dialog"><button type="button">Close</button></div>').querySelector("button");
    expect(plainKeyAllowed(key("j", { target: button }), hook())).toBe(false);
  });

  test.each([
    ["the series prompt", '<div id="calendar-series-scope"></div>'],
    ["the delete prompt", '<div id="calendar-delete-confirm"></div>'],
    ["the open command bar", '<div id="calendar-command" data-open="true"></div>'],
    ["the shortcut help", '<div id="calendar-shortcuts"></div>'],
    ["the import modal", '<div id="calendar-import"></div>'],
    ["an open core modal", '<div class="modal-overlay" style="display: flex;"></div>'],
  ])("refuses while %s is on the page", (_name, html) => {
    add(html);
    expect(plainKeyAllowed(key("j"), hook())).toBe(false);
  });

  test("ignores a closed command bar and a hidden core modal", () => {
    add('<div id="calendar-command"></div>');
    add('<div class="modal-overlay" style="display: none;"></div>');
    expect(document.querySelector(MODALS)).toBeNull();
    expect(plainKeyAllowed(key("j"), hook())).toBe(true);
  });
});

describe("isCommandKey", () => {
  test("is Ctrl K or Cmd K, in either case", () => {
    expect(isCommandKey({ key: "k", ctrlKey: true })).toBe(true);
    expect(isCommandKey({ key: "K", metaKey: true })).toBe(true);
  });

  test("is not a plain K, nor Ctrl K with Shift or Alt", () => {
    expect(isCommandKey({ key: "k" })).toBe(false);
    expect(isCommandKey({ key: "k", ctrlKey: true, shiftKey: true })).toBe(false);
    expect(isCommandKey({ key: "k", metaKey: true, altKey: true })).toBe(false);
    expect(isCommandKey({ key: "j", ctrlKey: true })).toBe(false);
  });
});

describe("digitOf", () => {
  test("reads a digit from the number row or the keypad", () => {
    expect(digitOf({ key: "0" })).toBe(0);
    expect(digitOf({ key: "7", code: "Numpad7" })).toBe(7);
  });

  test("reads a digit typed with Shift, as the AZERTY number row does", () => {
    expect(digitOf({ key: "3", shiftKey: true })).toBe(3);
  });

  test("is null for a symbol, a letter or a named key", () => {
    expect(digitOf({ key: "#", shiftKey: true })).toBeNull();
    expect(digitOf({ key: "a" })).toBeNull();
    expect(digitOf({ key: "F1" })).toBeNull();
  });
});

describe("isMac", () => {
  test("knows a Mac, an iPad and an iPhone by their platform", () => {
    expect(isMac({ platform: "MacIntel" })).toBe(true);
    expect(isMac({ userAgentData: { platform: "macOS" } })).toBe(true);
    expect(isMac({ platform: "iPad" })).toBe(true);
  });

  test("is false elsewhere, or without a navigator", () => {
    expect(isMac({ platform: "Win32" })).toBe(false);
    expect(isMac({ userAgentData: { platform: "Linux" } })).toBe(false);
    expect(isMac(undefined)).toBe(false);
  });
});
