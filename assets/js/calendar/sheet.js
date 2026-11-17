/**
 * Where the canvas's overlays go (the "+N more" list, quick create, the
 * band explainer): beside their anchor on a wide screen (calendar/popover.js),
 * or as a bottom sheet on a phone.
 *
 * A sheet carries `is-sheet`; calendar-phone.css draws it across the foot
 * of the screen, above the on-screen keyboard (--cal-kb-inset). Just
 * before it sits a `.cal-scrim` that dims the page and takes the tap that
 * closes the sheet, so that tap never reaches the grid underneath: the
 * scrim's click dispatches `calendar:dismiss` on its sheet for the owner
 * to close it, and the owners' outside-press handlers leave presses on a
 * scrim (`[data-sheet-scrim]`) to that click. `<html>` carries
 * `cal-sheet-open` while any sheet is open.
 *
 * The preview is not placed here: LiveView renders it, with its own scrim,
 * and CSS draws it as a sheet.
 */
import { placePopover } from "./popover.js";

// The room left between a draft and the top of the sheet over it.
export const SHEET_GAP = 8;

// Each sheet's scrim, so it can be removed after a redraw detached the sheet.
const scrims = new WeakMap();

/** `{sheet: true}` in sheet mode, else `placePopover`'s `{left, top, maxHeight?}`. */
export function placeOverlay(anchor, size, viewport, { sheet = false } = {}) {
  return sheet ? { sheet: true } : placePopover(anchor, size, viewport);
}

/** Applies a placement from `placeOverlay` to an element already in the page. */
export function applyPlacement(element, placement) {
  const sheet = placement.sheet === true;
  element.classList.toggle("is-sheet", sheet);
  element.style.left = sheet ? "" : `${Math.round(placement.left)}px`;
  element.style.top = sheet ? "" : `${Math.round(placement.top)}px`;
  element.style.maxHeight = !sheet && placement.maxHeight ? `${Math.round(placement.maxHeight)}px` : "";
  if (sheet) addScrim(element);
  else removeScrim(element);
  syncSheetOpen(element.ownerDocument);
}

/**
 * Forgets `element`'s sheet (its class and scrim; `element` may be null or
 * already detached) and brings `cal-sheet-open` up to date.
 */
export function releaseSheet(element, doc = document) {
  if (element) {
    element.classList.remove("is-sheet");
    removeScrim(element);
  }
  syncSheetOpen(doc);
}

/**
 * How many pixels the grid must scroll for the block at `blockRect` to sit
 * SHEET_GAP above the sheet at `sheetRect`, without taking the block's top
 * above `topLimit` (the foot of the sticky day header).
 */
export function sheetCovers(blockRect, sheetRect, topLimit = -Infinity) {
  const covered = Math.ceil(blockRect.bottom + SHEET_GAP - sheetRect.top);
  if (covered <= 0) return 0;
  return Math.max(0, Math.min(covered, Math.floor(blockRect.top - topLimit)));
}

/**
 * The part of the layout viewport (`layoutHeight`, window.innerHeight) the
 * on-screen keyboard covers, from `visual` (window.visualViewport). Zero
 * where the browser resizes the page for the keyboard instead.
 */
export function keyboardInset(layoutHeight, visual) {
  if (!visual) return 0;
  return Math.max(0, Math.round(layoutHeight - visual.height - visual.offsetTop));
}

function addScrim(element) {
  if (scrims.get(element)?.isConnected) return;
  const scrim = element.ownerDocument.createElement("div");
  scrim.className = "cal-scrim";
  scrim.setAttribute("data-sheet-scrim", "");
  scrim.setAttribute("aria-hidden", "true");
  // Pressing the scrim must not pull focus out of the sheet to <body>.
  for (const type of ["mousedown", "pointerdown"]) scrim.addEventListener(type, (e) => e.preventDefault());
  scrim.addEventListener("click", (e) => {
    e.stopPropagation();
    element.dispatchEvent(new CustomEvent("calendar:dismiss"));
  });
  element.before(scrim);
  scrims.set(element, scrim);
}

function removeScrim(element) {
  scrims.get(element)?.remove();
  scrims.delete(element);
}

function syncSheetOpen(doc) {
  doc.documentElement.classList.toggle("cal-sheet-open", !!doc.querySelector(".is-sheet"));
}
