/**
 * The calendar's one width test (calendar/viewport.js): phone mode is below
 * 40rem, asked of the window through matchMedia.
 */
import { expect, test, vi } from "vitest";
import { isPhone } from "../../calendar/viewport.js";

test("a window narrower than 40rem is a phone", () => {
  const win = { matchMedia: vi.fn((query) => ({ matches: query === "(width < 40rem)" })) };
  expect(isPhone(win)).toBe(true);
  expect(win.matchMedia).toHaveBeenCalledWith("(width < 40rem)");
});

test("a wider window is not a phone", () => {
  expect(isPhone({ matchMedia: () => ({ matches: false }) })).toBe(false);
});

test("a window without matchMedia is not a phone", () => {
  expect(isPhone({})).toBe(false);
});
