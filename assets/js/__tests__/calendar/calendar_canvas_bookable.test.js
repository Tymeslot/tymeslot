/**
 * Tests for the bookable-times layer in the CalendarCanvas hook
 * (hooks/calendar_canvas/bookable.js): B switches it, never while typing,
 * in a dialog, with a modifier or while quick create is open.
 */
import { afterEach, expect, test, vi } from "vitest";
import { addDays, makeScale } from "../../calendar/time.js";
import { mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

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

const w = (start, end) => ({ start, end });
const layer = (overrides = {}) => ({ on: true, meeting_type: { id: 1, name: "Intro call" }, windows: [], next: null, error: false, timezone: "Europe/London", ...overrides });
const thursday = [w("2026-10-15T09:00", "2026-10-15T17:00")];
const bands = (el) => [...el.querySelectorAll(".cal-bookable")];
const column = (el, iso) => el.querySelector(`.cal-col[data-day="${iso}"]`);
const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));

test("the layer pushed is drawn on the grid, with its label", () => {
  const { el, handlers } = mountHook();
  handlers["calendar:bookable"](layer({ windows: thursday }));

  expect(column(el, "2026-10-15").querySelectorAll(".cal-bookable")).toHaveLength(1);
  expect(column(el, "2026-10-15").querySelector("[data-bookable-label]").textContent).toBe("Bookable");
});

test("a calendar:ready reply carrying the layer draws it", () => {
  const { el } = mountHook(payload({ bookable: layer({ windows: thursday }) }));
  expect(bands(el)).toHaveLength(1);
});

test("a later events payload without a layer keeps the one drawn", () => {
  const { el, handlers } = mountHook();
  handlers["calendar:bookable"](layer({ windows: thursday }));
  handlers["calendar:events"](payload({ reset: false }));
  expect(bands(el)).toHaveLength(1);
});

test("B hides the bands at once, and shows them again", () => {
  const { el, handlers, hook } = mountHook();
  handlers["calendar:bookable"](layer({ windows: thursday }));

  press(document.body, "b");
  expect(bands(el)).toHaveLength(0);
  press(document.body, "b");
  expect(bands(el)).toHaveLength(1);
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([{}, {}]);
});

test("a layer pushed while a +N list is open waits for the list to close", () => {
  const { el, handlers, hook } = mountHook();
  const anchor = column(el, "2026-10-14");
  hook.showList([hook.cache.events.get("event-1")], anchor, "Events at this time");

  handlers["calendar:bookable"](layer({ windows: thursday }));
  expect(bands(el)).toHaveLength(0);

  hook.closeList();
  expect(bands(el)).toHaveLength(1);
});

function pointer(type, target, x, y) {
  const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });
  Object.defineProperty(e, "pointerId", { value: 1 });
  Object.defineProperty(e, "buttons", { value: type === "pointerup" ? 0 : 1 });
  return target.dispatchEvent(e);
}

test("a click on an empty slot over a band still drops a draft", () => {
  const { el, handlers, hook } = mountHook();
  hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  handlers["calendar:bookable"](layer({ windows: thursday }));
  // Even if the band were the target (its CSS keeps it out of hit testing).
  const band = column(el, "2026-10-15").querySelector(".cal-bookable");

  pointer("pointerdown", band, 350, 52 * 10 + 5);
  pointer("pointerup", band, 350, 52 * 10 + 5);
  band.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: 350, clientY: 52 * 10 + 5 }));

  const draft = el.querySelector("[data-draft-id]");
  expect(draft).not.toBeNull();
  expect(draft.closest("[data-day]").dataset.day).toBe("2026-10-15");
});

test("the note's Show goes to the next bookable time's week", () => {
  const { el, handlers, hook } = mountHook();
  handlers["calendar:bookable"](layer({ next: { at: "2026-10-20T09:00", label: "Tue 20 Oct, 09:00" } }));
  const show = el.querySelector("[data-bookable-show]");
  expect(el.querySelector(".cal-bookable-note").textContent).toBe("Next bookable time: Tue 20 Oct, 09:00 · Show");

  show.click();

  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-20" }]);
  expect(column(el, "2026-10-20")).not.toBeNull();
});

test("a scroll asked for by Show is dropped when the grid goes elsewhere first", () => {
  const { handlers, hook } = mountHook();
  handlers["calendar:bookable"](layer({ next: { at: "2026-10-20T09:00", label: "Tue 20 Oct, 09:00" } }));
  hook.showBookable("2026-10-20T09:00");
  hook.navigate({ view: "week", date: "2026-11-03" });
  expect(hook.scrollTarget).toBe(null);
});

test("the note's Show button is named with the note's context", () => {
  const { el, handlers } = mountHook();
  handlers["calendar:bookable"](layer({ next: { at: "2026-10-20T09:00", label: "Tue 20 Oct, 09:00" } }));
  expect(el.querySelector("[data-bookable-show]").getAttribute("aria-label")).toBe("Next bookable time: Tue 20 Oct, 09:00. Show");
});

test("B before any layer arrived only pushes the toggle", () => {
  const { el, hook } = mountHook();
  press(document.body, "b");
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([{}]);
  expect(hook.bookable).toBeNull();
  expect(el.querySelector(".cal-bookable, .cal-bookable-note")).toBeNull();
});

test("the note goes when the layer is switched off", () => {
  const { el, handlers } = mountHook();
  const next = { at: "2026-10-20T09:00", label: "Tue 20 Oct, 09:00" };
  handlers["calendar:bookable"](layer({ next }));
  expect(el.querySelector(".cal-bookable-note")).not.toBeNull();
  handlers["calendar:bookable"](layer({ next, on: false }));
  expect(el.querySelector(".cal-bookable-note")).toBeNull();
});
