/**
 * Tests for C and the toolbar's Create in the CalendarCanvas hook
 * (hooks/calendar_canvas/create.js): quick create at the next free slot,
 * and never while typing, in a dialog or with a modifier.
 */
import { afterEach, expect, test, vi } from "vitest";
import { block, mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

const popover = () => document.getElementById("calendar-quick-create");
const press = (target, key, extra = {}) => target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra }));
const drawnTime = (el) => el.querySelector("[data-draft-id] .cal-ev-time")?.textContent;

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
});

test("C opens quick create at the next free quarter hour today", () => {
  const { el } = mountHook();
  press(document.body, "c");

  expect(popover()).not.toBeNull();
  expect(drawnTime(el)).toBe("08:45");
  expect(el.querySelector("[data-draft-id]").closest("[data-day]").dataset.day).toBe("2026-10-14");
  expect(document.activeElement.id).toBe("calendar-qc-field");
});

test("C skips past a busy event", () => {
  const { el } = mountHook(payload({ now: "2026-10-14T10:50" }));
  press(document.body, "C");
  // Design review runs 11:00 to 12:00.
  expect(drawnTime(el)).toBe("12:00");
});

test("the toolbar's Create dispatches calendar:quick-create and gets the same", () => {
  const { el } = mountHook();
  el.dispatchEvent(new CustomEvent("calendar:quick-create", { bubbles: true }));
  expect(drawnTime(el)).toBe("08:45");
});

const nothingOpens = (el) => {
  expect(popover()).toBeNull();
  expect(el.querySelector("[data-draft-id]")).toBeNull();
};

test.each([
  ["Ctrl", { ctrlKey: true }],
  ["Cmd", { metaKey: true }],
  ["Alt", { altKey: true }],
  ["a repeating key", { repeat: true }],
])("C does nothing with %s", (_name, extra) => {
  const { el } = mountHook();
  press(document.body, "c", extra);
  nothingOpens(el);
});

test("C is the field's own letter in an input", () => {
  const { el } = mountHook();
  const input = document.createElement("input");
  document.body.appendChild(input);
  press(input, "c");
  nothingOpens(el);
});

test("C is the editor's own letter in a contenteditable element", () => {
  const { el } = mountHook();
  const editor = document.createElement("div");
  editor.setAttribute("contenteditable", "true");
  Object.defineProperty(editor, "isContentEditable", { value: true });
  document.body.appendChild(editor);
  press(editor, "c");
  nothingOpens(el);
});

test("C does nothing inside a dialog", () => {
  const { el } = mountHook();
  const dialog = document.createElement("div");
  dialog.setAttribute("role", "dialog");
  const inside = document.createElement("button");
  dialog.appendChild(inside);
  document.body.appendChild(dialog);
  press(inside, "c");
  nothingOpens(el);
});

test.each(["calendar-series-scope", "calendar-delete-confirm"])("C does nothing while #%s is open", (id) => {
  const { el } = mountHook();
  const modal = document.createElement("div");
  modal.id = id;
  document.body.appendChild(modal);
  press(document.body, "c");
  nothingOpens(el);
});

test("C does nothing in move mode", () => {
  const { el, hook } = mountHook();
  block(el, "event-1").focus();
  press(block(el, "event-1"), "m");
  expect(hook.moving).not.toBeNull();
  press(document.body, "c");
  expect(popover()).toBeNull();
});

test("C closes an open preview without a refocus, then opens quick create", () => {
  const { el, hook } = mountHook();
  const preview = document.createElement("div");
  preview.id = "calendar-preview";
  document.body.appendChild(preview);
  press(document.body, "c");

  expect(pushes(hook, "calendar:close_preview")).toEqual([{ refocus: "false" }]);
  expect(popover()).not.toBeNull();
  expect(drawnTime(el)).toBe("08:45");
});

test("C pushes no close when no preview is open", () => {
  const { hook } = mountHook();
  press(document.body, "c");
  expect(pushes(hook, "calendar:close_preview")).toEqual([]);
});

test("a folded night is skipped: C at 02:00 drafts at the first visible row", () => {
  const folded = payload({ now: "2026-10-14T02:00", settings: { ...payload().settings, fold_night: true } });
  const { el, hook } = mountHook(folded);
  press(document.body, "c");
  const floor = hook.currentScale().firstMinute;
  expect(floor).toBeGreaterThan(0);
  const [h, m] = drawnTime(el).slice(0, 5).split(":").map(Number);
  expect(h * 60 + m).toBeGreaterThanOrEqual(floor);
});

test("C from outside an open popover only returns to its field", () => {
  const { hook } = mountHook();
  press(document.body, "c");
  const first = hook.draft.id;
  document.activeElement.blur();
  expect(document.activeElement).toBe(document.body);
  press(document.body, "c");
  expect(hook.draft.id).toBe(first);
  expect(document.activeElement.id).toBe("calendar-qc-field");
});

test("late in the evening the grid moves to tomorrow when it is not in view", () => {
  vi.useFakeTimers();
  const { hook } = mountHook(payload({ now: "2026-10-18T22:30", date: "2026-10-14" }));
  press(document.body, "c");
  vi.advanceTimersByTime(0);

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-19" }]);
  expect(hook.draft).toMatchObject({ allDay: false });
  expect(hook.date).toBe("2026-10-19");
});

test("quick create's native inputs are named, not hidden, only when the pointer is coarse", () => {
  const coarse = (on) => vi.stubGlobal("matchMedia", (query) => ({ matches: on && query === "(pointer: coarse)" }));
  const hidden = () => popover().querySelector('[data-qc-input="start"]').hasAttribute("aria-hidden");

  coarse(true);
  mountHook();
  press(document.body, "c");
  expect(hidden()).toBe(false);
  unmountAll();
  popover()?.remove();

  coarse(false);
  mountHook();
  press(document.body, "c");
  expect(hidden()).toBe(true);
  vi.unstubAllGlobals();
});
