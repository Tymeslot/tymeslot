/**
 * Tests for the cascade overlap layout (calendar/layout.js), the part of the
 * redesign the spec's busy-day falsifier rests on: every visible event keeps
 * at least its first title line uncovered.
 */
import { describe, expect, test } from "vitest";
import { CHIP_WIDTH, countLines, layoutDay } from "../../calendar/layout.js";
import { makeScale } from "../../calendar/time.js";

const scale = makeScale(52, false);
// A stand-in for canvas measurement: 7px a character.
const measureLines = (text, width) => countLines(text, width, (word) => word.length * 7);
const opts = (colWidth) => ({ colWidth, hourHeight: 52, yOf: scale.yOf, measureLines });
const ev = (id, s, e, title = id, extra = {}) => ({ id, s, e, title, ...extra });
const events = (laid) => laid.filter((item) => !item.chip);
const chips = (laid) => laid.filter((item) => item.chip);

test("countLines wraps by whole words", () => {
  expect(countLines("Design review", 50, (w) => w.length * 7)).toBe(2);
  expect(countLines("Design review", 200, (w) => w.length * 7)).toBe(1);
});

test("a lone event takes the whole column", () => {
  const [item] = layoutDay([ev("a", 540, 600)], opts(200));
  expect(item).toMatchObject({ id: "a", left: 0, width: 200, level: 0 });
});

test("touching events do not overlap", () => {
  const laid = layoutDay([ev("a", 540, 600), ev("b", 600, 660)], opts(200));
  expect(laid.map((item) => [item.id, item.left, item.width])).toEqual([["a", 0, 200], ["b", 0, 200]]);
});

test("events starting within half an hour share the width", () => {
  const laid = layoutDay([ev("a", 540, 600), ev("b", 550, 620)], opts(200));
  expect(laid.map((item) => [item.id, item.left, item.width])).toEqual([["a", 0, 100], ["b", 100, 100]]);
});

test("a later event overlays the earlier one with an indent instead of halving it", () => {
  const laid = layoutDay([ev("a", 540, 720, "Workshop"), ev("b", 630, 690, "Lunch")], opts(200));
  const b = laid.find((item) => item.id === "b");
  expect(b).toMatchObject({ left: 36, width: 164, level: 1 });
  expect(b.z).toBeGreaterThan(laid.find((item) => item.id === "a").z);
});

test("a short event inside a long one overlays its right half", () => {
  const laid = layoutDay([ev("a", 540, 780, "Workshop"), ev("b", 555, 570, "Standup")], opts(200));
  expect(laid.find((item) => item.id === "b")).toMatchObject({ left: 100, width: 100, nestIn: "a" });
});

test("on a narrow column the short event leaves the long one its left third", () => {
  const laid = layoutDay([ev("a", 540, 780, "Workshop"), ev("b", 555, 570, "Standup")], opts(120));
  expect(laid.find((item) => item.id === "b")).toMatchObject({ left: 40, width: 80 });
});

describe("the +N more fold", () => {
  const five = (extra = {}) => ["a", "b", "c", "d", "e"].map((id) => ev(id, 540, 600, id, extra[id] || {}));

  test("columns that would fall below 56px fold behind a chip, keeping 64px columns", () => {
    const laid = layoutDay(five(), opts(200));
    expect(events(laid).map((item) => item.id)).toEqual(["a", "b"]);
    expect(events(laid).map((item) => item.width)).toEqual([85, 85]);
    const [chip] = chips(laid);
    expect(chip).toMatchObject({ left: 200 - CHIP_WIDTH, width: CHIP_WIDTH, warn: false });
    expect(chip.hidden).toEqual(["c", "d", "e"]);
    expect(chip.ids).toEqual(["a", "b", "c", "d", "e"]);
  });

  test("an event that needs attention is kept visible", () => {
    const laid = layoutDay(five({ e: { attention: true } }), opts(200));
    expect(events(laid).map((item) => item.id)).toEqual(["a", "e"]);
    expect(chips(laid)[0]).toMatchObject({ hidden: ["b", "c", "d"], warn: false });
  });

  test("when attention items outnumber the room, the chip carries a warning", () => {
    const all = { a: { attention: true }, b: { attention: true }, c: { attention: true }, d: { attention: true }, e: { attention: true } };
    const laid = layoutDay(five(all), opts(200));
    expect(chips(laid)[0]).toMatchObject({ hidden: ["c", "d", "e"], warn: true });
  });

  test("a wide column shows all five without folding", () => {
    expect(chips(layoutDay(five(), opts(400)))).toEqual([]);
  });
});
