/**
 * Tests for the bookable-times layer in the CalendarCanvas hook
 * (hooks/calendar_canvas/bookable.js): B switches it, never while typing,
 * in a dialog, with a modifier or while quick create is open.
 */
import { afterEach, expect, test, vi } from "vitest";
import { mountHook, pushes, unmountAll } from "./canvas_harness.js";

const press = (target, key, extra = {}) => target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra }));

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
});

test("B asks the server to switch the bookable layer", () => {
  const { hook } = mountHook();
  press(document.body, "b");
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([{}]);
});

test("Shift B does the same", () => {
  const { hook } = mountHook();
  press(document.body, "B", { shiftKey: true });
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([{}]);
});

test.each([
  ["Ctrl", { ctrlKey: true }],
  ["Cmd", { metaKey: true }],
  ["Alt", { altKey: true }],
  ["a repeating key", { repeat: true }],
])("B does nothing with %s", (_name, extra) => {
  const { hook } = mountHook();
  press(document.body, "b", extra);
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([]);
});

test("B is the field's own letter in an input", () => {
  const { hook } = mountHook();
  const input = document.createElement("input");
  document.body.appendChild(input);
  press(input, "b");
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([]);
});

test("B does nothing inside a dialog", () => {
  const { hook } = mountHook();
  const dialog = document.createElement("div");
  dialog.setAttribute("role", "dialog");
  const inside = document.createElement("button");
  dialog.appendChild(inside);
  document.body.appendChild(dialog);
  press(inside, "b");
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([]);
});

test("B does nothing while a delete prompt is open", () => {
  const { hook } = mountHook();
  const modal = document.createElement("div");
  modal.id = "calendar-delete-confirm";
  document.body.appendChild(modal);
  press(document.body, "b");
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([]);
});

test("B does nothing while quick create is open", () => {
  const { hook } = mountHook();
  press(document.body, "c");
  expect(document.getElementById("calendar-quick-create")).not.toBeNull();
  press(document.body, "b");
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([]);
});
