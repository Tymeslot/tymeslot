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
  expect(pushes(hook, "calendar:bookable_toggle")).toEqual([{ on: false }, { on: true }]);
});

test("a refused switch pushed back as the layer held redraws the bands", () => {
  const { el, handlers } = mountHook();
  handlers["calendar:bookable"](layer({ windows: thursday }));

  press(document.body, "b");
  expect(bands(el)).toHaveLength(0);
  handlers["calendar:bookable"](layer({ windows: thursday }));
  expect(bands(el)).toHaveLength(1);
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

const explainer = () => document.getElementById("calendar-bookable-explainer");
const status = () => explainer().querySelector("[data-bookable-status]");
const label = (el) => column(el, "2026-10-15").querySelector("[data-bookable-label]");
const replyTo = (hook, name) => hook.pushEventTo.mock.calls.find(([, pushed]) => pushed === name)[3];

function withLayer(windows = thursday) {
  const mounted = mountHook();
  mounted.handlers["calendar:bookable"](layer({ windows }));
  return mounted;
}

test("the label opens the explainer for its window, focus on its first button", () => {
  const { el } = withLayer();
  label(el).click();

  expect(explainer().getAttribute("role")).toBe("dialog");
  expect(explainer().textContent).toContain("Guests can book Intro call in the hatched times.");
  expect(explainer().querySelector(".cal-bookable-pop-time").textContent).toBe("Thu 15 Oct, 09:00 to 17:00");
  expect(document.activeElement.hasAttribute("data-bookable-copy")).toBe(true);
});

test("a second click on the label closes it", () => {
  const { el } = withLayer();
  label(el).click();
  label(el).click();
  expect(explainer()).toBeNull();
});

test("the explainer survives the minute tick and a new layer, which draws once it closes", () => {
  const { el, handlers, hook } = withLayer();
  label(el).click();

  hook.tick();
  handlers["calendar:bookable"](layer({ windows: [w("2026-10-16T09:00", "2026-10-16T17:00")] }));
  expect(explainer()).not.toBeNull();
  expect(column(el, "2026-10-16").querySelector(".cal-bookable")).toBeNull();

  press(explainer().querySelector("button"), "Escape");

  expect(explainer()).toBeNull();
  expect(column(el, "2026-10-16").querySelector(".cal-bookable")).not.toBeNull();
});

test("Escape closes it and gives focus back to the label", () => {
  const { el } = withLayer();
  label(el).click();
  press(explainer().querySelector("button"), "Escape");

  expect(explainer()).toBeNull();
  expect(document.activeElement).toBe(label(el));
});

test("a press outside closes it", () => {
  const { el } = withLayer();
  label(el).click();
  document.body.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true }));
  expect(explainer()).toBeNull();
});

test("a click on an empty slot while it is open only closes it", () => {
  const { el, hook } = withLayer();
  hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  label(el).click();
  const slot = column(el, "2026-10-17");

  pointer("pointerdown", slot, 550, 52 * 10);
  pointer("pointerup", slot, 550, 52 * 10);
  slot.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: 550, clientY: 52 * 10 }));

  expect(explainer()).toBeNull();
  expect(el.querySelector("[data-draft-id]")).toBeNull();
});

test("Copy free times copies the days in view with the time zone", async () => {
  const writeText = vi.fn().mockResolvedValue(undefined);
  Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true });
  const { el } = withLayer();
  label(el).click();

  explainer().querySelector("[data-bookable-copy]").click();

  await vi.waitFor(() => expect(status().textContent).toBe("Free times for these days copied."));
  expect(writeText).toHaveBeenCalledWith("Thu 15 Oct: 09:00 to 17:00\nTimes in Europe/London");
});

test("a refused copy says so", async () => {
  Object.defineProperty(navigator, "clipboard", { value: { writeText: vi.fn().mockRejectedValue(new Error("denied")) }, configurable: true });
  const { el } = withLayer();
  label(el).click();

  explainer().querySelector("[data-bookable-copy]").click();

  await vi.waitFor(() => expect(status().textContent).toBe("Couldn't copy. Your browser blocked the clipboard."));
});

test("Block this time sends the labelled window and closes once accepted", () => {
  const { el, hook } = withLayer();
  label(el).click();
  const block = explainer().querySelector("[data-bookable-block]");

  block.click();

  expect(pushes(hook, "calendar:block")).toEqual([{ start: "2026-10-15T09:00", end: "2026-10-15T17:00" }]);
  expect(status().textContent).toBe("Blocking…");
  expect(block.disabled).toBe(true);

  replyTo(hook, "calendar:block")({ accepted: true });
  expect(explainer()).toBeNull();
});

test("a refused block says why and stays open", () => {
  const { el, hook } = withLayer();
  label(el).click();
  const block = explainer().querySelector("[data-bookable-block]");
  block.click();

  replyTo(hook, "calendar:block")({ accepted: false, error: "That time can't be blocked." });

  expect(status().textContent).toBe("That time can't be blocked.");
  expect(block.disabled).toBe(false);
});

test("the label says whether its explainer is open", () => {
  const { el } = withLayer();
  expect(label(el).getAttribute("aria-expanded")).toBe("false");

  label(el).click();
  expect(label(el).getAttribute("aria-expanded")).toBe("true");

  label(el).click();
  expect(label(el).getAttribute("aria-expanded")).toBe("false");
});

test("B inside the explainer still switches the layer", () => {
  const { el, hook } = withLayer();
  label(el).click();

  press(explainer().querySelector("button"), "b");

  expect(pushes(hook, "calendar:bookable_toggle")).toHaveLength(1);
  expect(explainer()).toBeNull();
});

test("a reply for an explainer that has closed does not touch the one open now", () => {
  const { el, hook } = withLayer([w("2026-10-15T09:00", "2026-10-15T17:00"), w("2026-10-16T09:00", "2026-10-16T17:00")]);
  label(el).click();
  explainer().querySelector("[data-bookable-block]").click();
  const reply = replyTo(hook, "calendar:block");

  label(el).click();
  column(el, "2026-10-16").querySelector("[data-bookable-label]").click();
  const second = explainer();
  reply({ accepted: true });

  expect(explainer()).toBe(second);
});

test("an accepted block gives focus back to the day's label", () => {
  const { el, hook } = withLayer();
  label(el).click();
  explainer().querySelector("[data-bookable-block]").click();

  replyTo(hook, "calendar:block")({ accepted: true });

  expect(explainer()).toBeNull();
  expect(document.activeElement).toBe(label(el));
});

test("opening a \"+N\" list closes the explainer", () => {
  const { el, hook } = withLayer();
  label(el).click();

  hook.showList([], label(el), "More");

  expect(explainer()).toBeNull();
});

test("opening an event's preview closes the explainer", () => {
  const { el, hook } = withLayer();
  label(el).click();

  hook.open("event-1", label(el));

  expect(explainer()).toBeNull();
});

test("Copy falls back to the clipboard command when the clipboard API refuses", async () => {
  Object.defineProperty(navigator, "clipboard", { value: { writeText: vi.fn().mockRejectedValue(new Error("denied")) }, configurable: true });
  document.execCommand = vi.fn().mockReturnValue(true);
  const { el } = withLayer();
  label(el).click();

  explainer().querySelector("[data-bookable-copy]").click();

  await vi.waitFor(() => expect(status().textContent).toBe("Free times for these days copied."));
  expect(document.execCommand).toHaveBeenCalledWith("copy");
  expect(document.querySelector("textarea")).toBeNull();
});

test("Copy without a clipboard API uses the fallback, and says so when that fails too", async () => {
  Object.defineProperty(navigator, "clipboard", { value: undefined, configurable: true });
  document.execCommand = vi.fn().mockReturnValue(false);
  const { el } = withLayer();
  label(el).click();

  explainer().querySelector("[data-bookable-copy]").click();

  await vi.waitFor(() => expect(status().textContent).toBe("Couldn't copy. Your browser blocked the clipboard."));
});
