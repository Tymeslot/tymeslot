/**
 * Tests for overlay placement (calendar/sheet.js): beside the anchor on a
 * wide screen, a bottom sheet with a scrim on a phone; the scrim's click
 * asks the sheet's owner to close it; how far a draft must scroll to stay
 * above a sheet; and the on-screen keyboard's inset.
 */
import { afterEach, expect, test, vi } from "vitest";
import { placePopover } from "../../calendar/popover.js";
import { applyPlacement, keyboardInset, placeOverlay, releaseSheet, sheetCovers } from "../../calendar/sheet.js";

const anchor = { left: 400, right: 500, top: 300, bottom: 340 };
const size = { width: 320, height: 240 };
const viewport = { width: 1440, height: 900 };
const sheetOpen = () => document.documentElement.classList.contains("cal-sheet-open");

function overlay() {
  const host = document.createElement("div");
  const element = document.createElement("div");
  host.append(element);
  document.body.append(host);
  return { host, element };
}

afterEach(() => {
  document.body.innerHTML = "";
  document.documentElement.classList.remove("cal-sheet-open");
});

test("on a wide screen the overlay is placed as a popover", () => {
  expect(placeOverlay(anchor, size, viewport)).toEqual(placePopover(anchor, size, viewport));
  expect(placeOverlay(anchor, size, viewport, { sheet: false })).toEqual({ left: 508, top: 300 });
});

test("in sheet mode the overlay is a sheet whatever the anchor", () => {
  expect(placeOverlay(anchor, size, viewport, { sheet: true })).toEqual({ sheet: true });
});

test("a popover placement writes rounded pixels and leaves no scrim", () => {
  const { element } = overlay();
  applyPlacement(element, { left: 10.4, top: 20.6, maxHeight: 199.5 });

  expect(element.style.left).toBe("10px");
  expect(element.style.top).toBe("21px");
  expect(element.style.maxHeight).toBe("200px");
  expect(element.classList.contains("is-sheet")).toBe(false);
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("a sheet placement clears the position, adds one scrim before it and marks the page", () => {
  const { element } = overlay();
  applyPlacement(element, { left: 10, top: 20, maxHeight: 200 });
  applyPlacement(element, { sheet: true });
  applyPlacement(element, { sheet: true });

  expect(element.classList.contains("is-sheet")).toBe(true);
  expect(element.style.left).toBe("");
  expect(element.style.top).toBe("");
  expect(element.style.maxHeight).toBe("");
  expect(document.querySelectorAll(".cal-scrim")).toHaveLength(1);
  expect(element.previousElementSibling.matches('.cal-scrim[data-sheet-scrim][aria-hidden="true"]')).toBe(true);
  expect(sheetOpen()).toBe(true);
});

test("going back to a popover removes the scrim and the page mark", () => {
  const { element } = overlay();
  applyPlacement(element, { sheet: true });
  applyPlacement(element, { left: 10, top: 20 });

  expect(element.classList.contains("is-sheet")).toBe(false);
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("a click on the scrim asks the sheet to close and goes no further", () => {
  const { host, element } = overlay();
  const dismissed = vi.fn();
  const hostSaw = vi.fn();
  element.addEventListener("calendar:dismiss", dismissed);
  host.addEventListener("click", hostSaw);
  applyPlacement(element, { sheet: true });

  element.previousElementSibling.click();

  expect(dismissed).toHaveBeenCalledTimes(1);
  expect(hostSaw).not.toHaveBeenCalled();
});

test("releasing a sheet removes its scrim even when a redraw has detached the sheet", () => {
  const { element } = overlay();
  const other = overlay().element;
  applyPlacement(element, { sheet: true });
  applyPlacement(other, { sheet: true });

  element.remove();
  releaseSheet(element);
  expect(document.querySelectorAll(".cal-scrim")).toHaveLength(1);
  expect(sheetOpen()).toBe(true);

  releaseSheet(other);
  expect(document.querySelector(".cal-scrim")).toBeNull();
  expect(sheetOpen()).toBe(false);
});

test("releasing nothing only brings the page mark up to date", () => {
  document.documentElement.classList.add("cal-sheet-open");
  releaseSheet(null);
  expect(sheetOpen()).toBe(false);
});

test("a draft under the sheet scrolls up by the overlap plus a gap", () => {
  expect(sheetCovers({ top: 600, bottom: 652 }, { top: 500 })).toBe(160);
});

test("a draft already above the sheet does not move", () => {
  expect(sheetCovers({ top: 400, bottom: 480 }, { top: 500 })).toBe(0);
  expect(sheetCovers({ top: 400, bottom: 492 }, { top: 500 })).toBe(0);
});

test("a tall draft never scrolls above the limit given", () => {
  expect(sheetCovers({ top: 120, bottom: 700 }, { top: 500 }, 80)).toBe(40);
  expect(sheetCovers({ top: 60, bottom: 700 }, { top: 500 }, 80)).toBe(0);
});

test("the keyboard inset is the part of the layout viewport the keyboard covers", () => {
  expect(keyboardInset(844, undefined)).toBe(0);
  expect(keyboardInset(844, { height: 844, offsetTop: 0 })).toBe(0);
  expect(keyboardInset(844, { height: 500, offsetTop: 0 })).toBe(344);
  expect(keyboardInset(844, { height: 500, offsetTop: 100 })).toBe(244);
  expect(keyboardInset(844, { height: 499.6, offsetTop: 0 })).toBe(344);
});

test("a browser that resizes the page for the keyboard leaves no inset", () => {
  expect(keyboardInset(500, { height: 500, offsetTop: 0 })).toBe(0);
  expect(keyboardInset(500, { height: 520, offsetTop: 0 })).toBe(0);
});
