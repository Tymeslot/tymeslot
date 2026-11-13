/**
 * The browser tab's id (calendar/tab_id.js), which the hook sends with
 * calendar:ready so that after a reload only the tab that deleted is offered
 * Undo: a reload of the tab keeps it, another tab gets its own, and a browser
 * that keeps no storage sends none.
 */
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { TAB_ID_KEY, tabId } from "../../calendar/tab_id.js";
import { mountHook, unmountAll } from "./canvas_harness.js";

// A sessionStorage of its own, standing in for another tab's.
const otherTab = () => {
  const items = new Map();
  return { getItem: (key) => items.get(key) ?? null, setItem: (key, value) => items.set(key, value) };
};

beforeEach(() => sessionStorage.clear());

afterEach(() => {
  unmountAll();
  vi.restoreAllMocks();
  sessionStorage.clear();
});

test("the hook sends the tab's id with calendar:ready, and a reload sends the same one", () => {
  const first = mountHook().readyParams.tab;
  expect(first).toEqual(expect.any(String));
  expect(first).not.toBe("");
  expect(sessionStorage.getItem(TAB_ID_KEY)).toBe(first);

  unmountAll();
  expect(mountHook().readyParams.tab).toBe(first);
});

test("another tab gets an id of its own", () => {
  const mine = tabId();
  expect(tabId(otherTab())).not.toBe(mine);
});

test("a browser whose storage refuses sends no id", () => {
  vi.spyOn(Storage.prototype, "getItem").mockImplementation(() => {
    throw new DOMException("blocked", "SecurityError");
  });

  expect(mountHook().readyParams.tab).toBeNull();
});

test("a browser that refuses even to hand out sessionStorage sends no id", () => {
  vi.spyOn(window, "sessionStorage", "get").mockImplementation(() => {
    throw new DOMException("blocked", "SecurityError");
  });

  expect(tabId()).toBeNull();
  expect(mountHook().readyParams.tab).toBeNull();
});

test("a browser with no sessionStorage at all sends no id", () => {
  vi.spyOn(window, "sessionStorage", "get").mockReturnValue(undefined);

  expect(tabId()).toBeNull();
});
