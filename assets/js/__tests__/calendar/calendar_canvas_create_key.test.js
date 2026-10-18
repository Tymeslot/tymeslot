/**
 * Tests for C and the toolbar's Create in the CalendarCanvas hook
 * (hooks/calendar_canvas/create.js): quick create at the next free slot,
 * and never while typing, in a dialog or with a modifier.
 */
import { afterEach, expect, test, vi } from "vitest";
import { mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

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
  expect(drawnTime(el)).toBe("08:45–09:15");
  expect(el.querySelector("[data-draft-id]").closest("[data-day]").dataset.day).toBe("2026-10-14");
  expect(document.activeElement.id).toBe("calendar-qc-field");
});

test("C skips past a busy event", () => {
  const { el } = mountHook(payload({ now: "2026-10-14T10:50" }));
  press(document.body, "C");
  // Design review runs 11:00 to 12:00.
  expect(drawnTime(el)).toBe("12:00–12:30");
});

test("the toolbar's Create dispatches calendar:quick-create and gets the same", () => {
  const { el } = mountHook();
  el.dispatchEvent(new CustomEvent("calendar:quick-create", { bubbles: true }));
  expect(drawnTime(el)).toBe("08:45–09:15");
});

test("C is the field's own letter while typing, and does nothing with a modifier or in a dialog", () => {
  const { el } = mountHook();
  const input = document.createElement("input");
  document.body.appendChild(input);
  press(input, "c");
  press(document.body, "c", { ctrlKey: true });
  press(document.body, "c", { metaKey: true });
  const dialog = document.createElement("div");
  dialog.setAttribute("role", "dialog");
  const inside = document.createElement("button");
  dialog.appendChild(inside);
  document.body.appendChild(dialog);
  press(inside, "c");

  expect(popover()).toBeNull();
  expect(el.querySelector("[data-draft-id]")).toBeNull();
});

test("C while quick create is open only returns to its field", () => {
  const { hook } = mountHook();
  press(document.body, "c");
  const first = hook.draft.id;
  document.body.focus();
  hook.quickCreateNext();
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
