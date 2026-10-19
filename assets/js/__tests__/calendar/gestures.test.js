/**
 * Tests for the calendar's touch gesture maths (calendar/gestures.js).
 */
import { describe, expect, test } from "vitest";
import { movedBeyond } from "../../calendar/gestures.js";

describe("movedBeyond", () => {
  test("a finger that wanders less than 8px is still pressing", () => {
    expect(movedBeyond({ x: 100, y: 100 }, { x: 105, y: 106 })).toBe(false);
  });

  test("exactly 8px is still a press", () => {
    expect(movedBeyond({ x: 100, y: 100 }, { x: 108, y: 100 })).toBe(false);
  });

  test("a finger past 8px, in any direction, has moved", () => {
    expect(movedBeyond({ x: 100, y: 100 }, { x: 106, y: 106 })).toBe(true);
    expect(movedBeyond({ x: 100, y: 100 }, { x: 100, y: 91 })).toBe(true);
  });

  test("the slop can be widened", () => {
    expect(movedBeyond({ x: 100, y: 100 }, { x: 106, y: 106 }, 10)).toBe(false);
  });
});
