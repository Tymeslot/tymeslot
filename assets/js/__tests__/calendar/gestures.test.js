/**
 * Tests for the calendar's touch gesture maths (calendar/gestures.js).
 */
import { describe, expect, test } from "vitest";
import { movedBeyond, pinchDistance, pinchedHour, swipeOffset, swipeStep } from "../../calendar/gestures.js";

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

describe("swipeStep", () => {
  const start = { x: 300, y: 300 };

  test("a quick swipe to the left asks for the next period", () => {
    expect(swipeStep(start, { x: 220, y: 310 }, 200)).toBe(1);
  });

  test("a quick swipe to the right asks for the previous period", () => {
    expect(swipeStep(start, { x: 380, y: 290 }, 200)).toBe(-1);
  });

  test("60px sideways at 1.5 times the vertical travel is just enough", () => {
    expect(swipeStep(start, { x: 240, y: 340 }, 200)).toBe(1);
  });

  test("less than 60px sideways is not a swipe", () => {
    expect(swipeStep(start, { x: 241, y: 300 }, 200)).toBe(0);
  });

  test("a move nearly as far up or down as sideways is not a swipe", () => {
    expect(swipeStep(start, { x: 220, y: 360 }, 200)).toBe(0);
  });

  test("a slow drag is not a swipe", () => {
    expect(swipeStep(start, { x: 200, y: 300 }, 601)).toBe(0);
  });
});

describe("swipeOffset", () => {
  test("no travel, no offset", () => {
    expect(swipeOffset(0, 400)).toBe(0);
  });

  test("a short move is followed almost one for one", () => {
    const offset = swipeOffset(10, 400);
    expect(offset).toBeGreaterThan(9);
    expect(offset).toBeLessThan(10);
  });

  test("a long move is followed less and less, never past 40% of the width", () => {
    expect(swipeOffset(200, 400)).toBeLessThan(swipeOffset(400, 400));
    expect(swipeOffset(5000, 400)).toBeLessThan(160);
    expect(swipeOffset(5000, 400)).toBeGreaterThan(150);
  });

  test("leftward and rightward follow alike", () => {
    expect(swipeOffset(-100, 400)).toBe(-swipeOffset(100, 400));
  });
});

describe("pinch", () => {
  test("pinchDistance is the straight line between two fingers", () => {
    expect(pinchDistance({ x: 0, y: 0 }, { x: 30, y: 40 })).toBe(50);
  });

  test("spreading the fingers half as far again makes the hours half as tall again", () => {
    expect(pinchedHour(52, 100, 150)).toBe(78);
  });

  test("closing them to half makes the hours half as tall", () => {
    expect(pinchedHour(52, 100, 50)).toBe(26);
  });

  test("the hours stay within the zoom's bounds", () => {
    expect(pinchedHour(52, 100, 1000)).toBe(128);
    expect(pinchedHour(52, 100, 10)).toBe(24);
  });

  test("fingers that started on one spot leave the height alone", () => {
    expect(pinchedHour(52, 0, 80)).toBe(52);
  });
});
