/**
 * Tests for the canvas's overlays as bottom sheets on a phone
 * (calendar/sheet.js through the CalendarCanvas hook): the "+N" list, the
 * band explainer and quick create open as sheets over a scrim whose tap
 * closes them without reaching the grid; the preview is left to CSS; the
 * draft scrolls clear of quick create's sheet; and the on-screen keyboard's
 * height reaches CSS. On a wide screen they stay popovers.
 */
import { afterEach, expect, test, vi } from "vitest";
import { addDays, makeScale } from "../../calendar/time.js";
import { VIEWPORT_DEBOUNCE_MS } from "../../hooks/calendar_canvas/viewport.js";
import { block, event, mockViewport, mountHook, payload, settings, unmountAll } from "./canvas_harness.js";

const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const crowd = () => ["a", "b", "c", "d", "e", "f", "g", "h"].map((id) => event(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
const layer = { on: true, meeting_type: { id: 1, name: "Intro call" }, windows: [{ start: "2026-10-15T09:00", end: "2026-10-15T17:00" }], next: null, error: false, timezone: "Europe/London" };
const popover = () => document.getElementById("calendar-quick-create");
const sheetOpen = () => document.documentElement.classList.contains("cal-sheet-open");
const press = (target) => target.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true, cancelable: true }));

// Quick create on Thursday 15 October, 09:00, from a click on the empty slot.
function openQuickCreate() {
  const mounted = mountHook();
  mounted.hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  const column = mounted.el.querySelector('.cal-col[data-day="2026-10-15"]');
  column.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: 350, clientY: 52 * 9 + 10 }));
  return mounted;
}

function type(text) {
  const field = document.getElementById("calendar-qc-field");
  field.value = text;
  field.dispatchEvent(new Event("input", { bubbles: true }));
}

afterEach(() => {
  unmountAll();
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
  vi.useRealTimers();
  document.documentElement.classList.remove("cal-sheet-open");
});

test("on a phone the +N list opens as a bottom sheet over a scrim", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ events: crowd() }));
  const chip = el.querySelector(".cal-more");
  expect(chip).not.toBeNull();
  chip.click();

  const list = el.querySelector(".cal-list");
  expect(list.classList.contains("is-sheet")).toBe(true);
  expect(list.style.left).toBe("");
  expect(list.style.top).toBe("");
  expect(list.previousElementSibling.matches('.cal-scrim[aria-hidden="true"]')).toBe(true);
  expect(sheetOpen()).toBe(true);
});

test("a tap on the list's scrim closes it, gives focus back to its chip and never reaches the grid", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ events: crowd() }));
  el.querySelector(".cal-more").click();
  const scrim = el.querySelector(".cal-scrim");

  press(scrim);
  // The press alone leaves the sheet: its click is the scrim's.
  expect(el.querySelector(".cal-list")).not.toBeNull();

  scrim.click();
  expect(el.querySelector(".cal-list")).toBeNull();
  expect(el.querySelector(".cal-scrim")).toBeNull();
  expect(el.querySelector("[data-draft-id]")).toBeNull();
  expect(popover()).toBeNull();
  expect(sheetOpen()).toBe(false);
  expect(document.activeElement).toBe(el.querySelector(".cal-more"));
});

test("a redraw that drops an open list takes its sheet state with it", () => {
  mockViewport(true);
  const { el, handlers } = mountHook(payload({ events: crowd() }));
  el.querySelector(".cal-more").click();

  handlers["calendar:settings"]({ ...settings, density: "compact" });

  expect(el.querySelector(".cal-list")).toBeNull();
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("destroying the hook with the explainer open as a sheet frees the page", () => {
  mockViewport(true);
  const { el, handlers } = mountHook();
  handlers["calendar:bookable"](layer);
  el.querySelector('.cal-col[data-day="2026-10-15"] [data-bookable-label]').click();
  expect(sheetOpen()).toBe(true);

  unmountAll();

  expect(sheetOpen()).toBe(false);
});

test("on a wide screen the +N list stays a popover beside its chip", () => {
  mockViewport(false);
  const { el } = mountHook(payload({ events: crowd() }));
  el.querySelector(".cal-more").click();

  const list = el.querySelector(".cal-list");
  expect(list.classList.contains("is-sheet")).toBe(false);
  expect(list.style.left).toMatch(/^-?\d+px$/);
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("on a phone the band explainer is a sheet, and its scrim closes it", () => {
  mockViewport(true);
  const { el, handlers } = mountHook();
  handlers["calendar:bookable"](layer);
  el.querySelector('.cal-col[data-day="2026-10-15"] [data-bookable-label]').click();

  const explainer = document.getElementById("calendar-bookable-explainer");
  expect(explainer.classList.contains("is-sheet")).toBe(true);
  expect(sheetOpen()).toBe(true);

  const scrim = explainer.previousElementSibling;
  press(scrim);
  expect(document.getElementById("calendar-bookable-explainer")).not.toBeNull();
  scrim.click();
  expect(document.getElementById("calendar-bookable-explainer")).toBeNull();
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("on a phone quick create opens as a sheet over a scrim", () => {
  mockViewport(true);
  openQuickCreate();

  expect(popover().classList.contains("is-sheet")).toBe(true);
  expect(popover().style.left).toBe("");
  expect(popover().previousElementSibling.matches(".cal-scrim")).toBe(true);
  expect(sheetOpen()).toBe(true);
  expect(document.activeElement.id).toBe("calendar-qc-field");
});

test("a tap on quick create's scrim cancels the draft without dropping a new one", () => {
  mockViewport(true);
  const { el, hook } = openQuickCreate();
  const scrim = popover().previousElementSibling;

  press(scrim);
  expect(popover()).not.toBeNull();

  scrim.click();
  expect(popover()).toBeNull();
  expect(hook.draft).toBeNull();
  expect(el.querySelector("[data-draft-id]")).toBeNull();
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("on a phone a draft the sheet would cover scrolls up to just above it", () => {
  mockViewport(true);
  let draftBox = { left: 300, right: 400, top: 200, bottom: 226, width: 100, height: 26 };
  vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function () {
    if (this.matches("[data-draft-id]")) return draftBox;
    if (this.id === "calendar-quick-create") return { left: 0, right: 390, top: 500, bottom: 844, width: 390, height: 344 };
    if (this.classList.contains("cal-top")) return { left: 0, right: 390, top: 44, bottom: 80, width: 390, height: 36 };
    return { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 };
  });
  const { el } = openQuickCreate();
  const scroller = () => el.querySelector("[data-scroll]");
  const before = scroller().scrollTop;

  // The typed time moves the draft to where the sheet lies over it.
  draftBox = { ...draftBox, top: 600, bottom: 652 };
  type("Dentist 18:00");

  expect(scroller().scrollTop - before).toBe(160);
});

test("on a wide screen quick create stays a popover beside the draft and the grid does not scroll", () => {
  mockViewport(false);
  const { el } = openQuickCreate();
  const before = el.querySelector("[data-scroll]").scrollTop;
  type("Dentist 18:00");

  expect(popover().classList.contains("is-sheet")).toBe(false);
  expect(popover().style.left).toMatch(/^-?\d+px$/);
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(el.querySelector("[data-scroll]").scrollTop).toBe(before);
});

test("on a phone the preview is left to CSS: no position variables", () => {
  mockViewport(true);
  const { el } = mountHook();
  block(el, "event-1").click();

  const style = document.documentElement.style;
  expect(style.getPropertyValue("--cal-pop-x")).toBe("");
  expect(style.getPropertyValue("--cal-pop-y")).toBe("");
  expect(style.getPropertyValue("--cal-pop-h")).toBe("");
});

test("on a wide screen the preview is still placed beside its event", () => {
  mockViewport(false);
  const { el } = mountHook();
  block(el, "event-1").click();

  expect(document.documentElement.style.getPropertyValue("--cal-pop-x")).toMatch(/^-?\d+px$/);
});

test("the on-screen keyboard's height reaches CSS as --cal-kb-inset, and goes with the hook", () => {
  vi.stubGlobal("innerHeight", 844);
  const visual = Object.assign(new EventTarget(), { height: 844, offsetTop: 0 });
  vi.stubGlobal("visualViewport", visual);
  mockViewport(true);
  mountHook();
  const inset = () => document.documentElement.style.getPropertyValue("--cal-kb-inset");
  expect(inset()).toBe("0px");

  visual.height = 500;
  visual.dispatchEvent(new Event("resize"));
  expect(inset()).toBe("344px");

  visual.offsetTop = 100;
  visual.dispatchEvent(new Event("scroll"));
  expect(inset()).toBe("244px");

  unmountAll();
  expect(inset()).toBe("");
});

test("a press on the scrim does not take focus out of the sheet", () => {
  mockViewport(true);
  const { el } = mountHook(payload({ events: crowd() }));
  el.querySelector(".cal-more").click();
  const scrim = el.querySelector(".cal-scrim");

  for (const type of ["mousedown", "pointerdown"]) {
    const down = new MouseEvent(type, { bubbles: true, cancelable: true });
    scrim.dispatchEvent(down);
    expect(down.defaultPrevented).toBe(true);
  }
});

test("a flip to a wide screen closes the list and the explainer and leaves no sheet", () => {
  vi.useFakeTimers();
  const media = mockViewport(true);
  const { el } = mountHook(payload({ events: crowd() }));
  el.querySelector(".cal-more").click();
  expect(el.querySelector(".cal-list.is-sheet")).not.toBeNull();

  media.set(false);
  vi.advanceTimersByTime(VIEWPORT_DEBOUNCE_MS);

  expect(el.querySelector(".cal-list")).toBeNull();
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("a flip to a wide screen turns quick create's sheet back into a popover", () => {
  vi.useFakeTimers();
  const media = mockViewport(true);
  openQuickCreate();
  expect(popover().classList.contains("is-sheet")).toBe(true);

  media.set(false);
  vi.advanceTimersByTime(VIEWPORT_DEBOUNCE_MS);

  expect(popover().classList.contains("is-sheet")).toBe(false);
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("the keyboard rising scrolls the draft clear of quick create's sheet", () => {
  vi.stubGlobal("innerHeight", 844);
  const visual = Object.assign(new EventTarget(), { height: 844, offsetTop: 0 });
  vi.stubGlobal("visualViewport", visual);
  mockViewport(true);
  let sheetTop = 600;
  vi.spyOn(Element.prototype, "getBoundingClientRect").mockImplementation(function () {
    if (this.matches("[data-draft-id]")) return { left: 300, right: 400, top: 400, bottom: 426, width: 100, height: 26 };
    if (this.id === "calendar-quick-create") return { left: 0, right: 390, top: sheetTop, bottom: 844, width: 390, height: 844 - sheetTop };
    if (this.classList.contains("cal-top")) return { left: 0, right: 390, top: 44, bottom: 80, width: 390, height: 36 };
    return { left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0 };
  });
  const { el } = openQuickCreate();
  const scroller = el.querySelector("[data-scroll]");
  const before = scroller.scrollTop;

  // The keyboard lifts the sheet to where it lies over the draft.
  sheetTop = 300;
  visual.height = 500;
  visual.dispatchEvent(new Event("resize"));

  expect(scroller.scrollTop - before).toBe(134);
});
