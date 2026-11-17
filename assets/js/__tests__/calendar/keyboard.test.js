/**
 * Tests for the calendar's keyboard model (calendar/keyboard.js): focus
 * moving between events, and the move mode's steps.
 */
import { describe, expect, test } from "vitest";
import { beginMove, moveStep, nextFocus } from "../../calendar/keyboard.js";
import { MINUTES_PER_DAY } from "../../calendar/time.js";

// Mon (day 0) holds A at 09:00 and B at 10:00, Tue holds C at 09:30,
// Wednesday is empty, Thu holds D at 15:00.
const items = [
  { id: "A", day: 0, minute: 540, order: 0 },
  { id: "B", day: 0, minute: 600, order: 1 },
  { id: "C", day: 1, minute: 570, order: 2 },
  { id: "D", day: 3, minute: 900, order: 3 },
];
const at = (id, day) => ({ id, day });
const go = (from, key) => nextFocus(items, from, key)?.id ?? null;

describe("focus", () => {
  test("up and down move within the day", () => {
    expect(go(at("A", 0), "ArrowDown")).toBe("B");
    expect(go(at("B", 0), "ArrowUp")).toBe("A");
    expect(go(at("A", 0), "ArrowUp")).toBe(null);
  });

  test("left and right go to the nearest event on the next day that has one", () => {
    expect(go(at("A", 0), "ArrowRight")).toBe("C");
    expect(go(at("C", 1), "ArrowRight")).toBe("D");
    expect(go(at("D", 3), "ArrowLeft")).toBe("C");
    expect(go(at("D", 3), "ArrowRight")).toBe(null);
  });

  test("left and right pick the first listed event when two in the next column are equally near", () => {
    const tied = [
      { id: "A", day: 0, minute: 600, order: 0 },
      { id: "L", day: 1, minute: 540, order: 1 },
      { id: "M", day: 1, minute: 660, order: 2 },
    ];
    expect(nextFocus(tied, at("A", 0), "ArrowRight")?.id).toBe("L");
    expect(nextFocus([tied[0], tied[2], tied[1]], at("A", 0), "ArrowRight")?.id).toBe("M");
  });

  test("home and end go to the day's first and last event", () => {
    expect(go(at("B", 0), "Home")).toBe("A");
    expect(go(at("A", 0), "End")).toBe("B");
  });

  test("an answer names the day too, for an event drawn on two", () => {
    expect(nextFocus(items, at("A", 0), "ArrowRight")).toEqual({ id: "C", day: 1 });
  });
});

describe("move mode", () => {
  const day = 20_000 * MINUTES_PER_DAY;
  const range = beginMove({ id: "A", startMin: day + 540, endMin: day + 600 }).range;
  const bounds = { firstMinute: 0, firstDay: 19_999, lastDay: 20_001 };
  const step = (from, key, shift = false) => moveStep(from, key, { ...bounds, shift });

  test("up and down shift by a quarter hour within the day", () => {
    expect(step(range, "ArrowDown")).toEqual({ startMin: day + 555, endMin: day + 615 });
    expect(step({ startMin: day, endMin: day + 60 }, "ArrowUp")).toEqual({ startMin: day, endMin: day + 60 });
    expect(step({ startMin: day + 1380, endMin: day + 1440 }, "ArrowDown")).toEqual({ startMin: day + 1380, endMin: day + 1440 });
  });

  test("an off-grid event snaps to the grid on its first step", () => {
    const off = { startMin: day + 547, endMin: day + 607 };
    expect(step(off, "ArrowUp")).toEqual({ startMin: day + 525, endMin: day + 585 });
    expect(step(off, "ArrowDown")).toEqual({ startMin: day + 555, endMin: day + 615 });
  });

  test("shift with left or right changes nothing", () => {
    expect(step(range, "ArrowLeft", true)).toEqual(range);
    expect(step(range, "ArrowRight", true)).toEqual(range);
  });

  test("shift with up and down changes the length, never below a quarter hour", () => {
    expect(step(range, "ArrowDown", true)).toEqual({ startMin: day + 540, endMin: day + 615 });
    expect(step({ startMin: day + 540, endMin: day + 555 }, "ArrowUp", true)).toEqual({ startMin: day + 540, endMin: day + 555 });
  });

  test("left and right move a day within the visible days", () => {
    expect(step(range, "ArrowRight")).toEqual({ startMin: day + MINUTES_PER_DAY + 540, endMin: day + MINUTES_PER_DAY + 600 });
    const lastDay = { startMin: day + MINUTES_PER_DAY + 540, endMin: day + MINUTES_PER_DAY + 600 };
    expect(step(lastDay, "ArrowRight")).toEqual(lastDay);
  });

  test("never moves into the folded night", () => {
    const folded = moveStep({ startMin: day + 420, endMin: day + 480 }, "ArrowUp", { ...bounds, shift: false, firstMinute: 420 });
    expect(folded).toEqual({ startMin: day + 420, endMin: day + 480 });
  });
});
