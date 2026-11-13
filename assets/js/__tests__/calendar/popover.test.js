/**
 * Tests for popover placement (calendar/popover.js): a popover never covers
 * the event it describes when there is room beside it, and always stays
 * inside the viewport.
 */
import { expect, test } from "vitest";
import { placePopover } from "../../calendar/popover.js";

const viewport = { width: 1440, height: 900 };
const size = { width: 320, height: 240 };

test("sits to the right of the anchor when there is room", () => {
  expect(placePopover({ left: 400, right: 500, top: 300, bottom: 340 }, size, viewport)).toEqual({ left: 508, top: 300 });
});

test("flips to the left near the right edge", () => {
  expect(placePopover({ left: 1100, right: 1200, top: 300, bottom: 340 }, size, viewport)).toEqual({ left: 772, top: 300 });
});

test("drops below when neither side fits", () => {
  const narrow = { width: 400, height: 900 };
  expect(placePopover({ left: 60, right: 340, top: 300, bottom: 340 }, size, narrow)).toEqual({ left: 60, top: 348 });
});

test("goes above when below would leave the viewport", () => {
  const narrow = { width: 400, height: 600 };
  expect(placePopover({ left: 60, right: 340, top: 500, bottom: 540 }, size, narrow)).toEqual({ left: 60, top: 252 });
});

test("is clamped vertically inside the viewport", () => {
  expect(placePopover({ left: 400, right: 500, top: 800, bottom: 840 }, size, viewport)).toEqual({ left: 508, top: 652 });
});

test("clamps horizontally when dropping below or above", () => {
  const narrow = { width: 400, height: 800 };
  expect(placePopover({ left: -20, right: 380, top: 100, bottom: 140 }, size, narrow)).toEqual({ left: 8, top: 148 });
});

test("goes right when it fits exactly at the viewport margin", () => {
  expect(placePopover({ left: 900, right: 1104, top: 300, bottom: 340 }, size, viewport)).toEqual({ left: 1112, top: 300 });
  expect(placePopover({ left: 900, right: 1105, top: 300, bottom: 340 }, size, viewport).left).not.toBe(1113);
});

test("uses the larger side with a maxHeight when neither fits in full", () => {
  const desktop = { width: 1280, height: 800 };
  expect(placePopover({ left: 300, right: 1250, top: 100, bottom: 650 }, size, desktop)).toEqual({ left: 300, top: 658, maxHeight: 134 });
  const phone = { width: 390, height: 700 };
  expect(placePopover({ left: 60, right: 170, top: 150, bottom: 560 }, size, phone)).toEqual({ left: 60, top: 8, maxHeight: 134 });
});

test("uses the space above, scrolled, when it is the larger side", () => {
  const phone = { width: 390, height: 700 };
  expect(placePopover({ left: 60, right: 170, top: 200, bottom: 660 }, size, phone)).toEqual({ left: 60, top: 8, maxHeight: 184 });
});

test("right-aligns inside a wide anchor to keep its title clear when space is short", () => {
  const desktop = { width: 1280, height: 800 };
  expect(placePopover({ left: 300, right: 1250, top: 100, bottom: 700 }, size, desktop)).toEqual({ left: 930, top: 8 });
});

test("starts below the title line when the anchor is too narrow to right-align", () => {
  const phone = { width: 390, height: 700 };
  expect(placePopover({ left: 60, right: 170, top: 100, bottom: 600 }, size, phone)).toEqual({ left: 60, top: 132 });
});
