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
