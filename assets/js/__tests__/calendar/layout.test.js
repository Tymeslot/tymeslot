/**
 * Tests for the cascade overlap layout (calendar/layout.js), the part of the
 * redesign the spec's busy-day falsifier rests on: every visible event keeps
 * at least its first title line uncovered.
 */
import { describe, expect, test } from "vitest";
import { CHIP_WIDTH, LINE_HEIGHT, PAD_TOP, countLines, layoutColumn, layoutDay, placeDay } from "../../calendar/layout.js";
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

  test("folding starts below 56px a column, not at 64px", () => {
    const three = ["a", "b", "c"].map((id) => ev(id, 540, 600));
    expect(chips(layoutDay(three, opts(168)))).toEqual([]);
    expect(chips(layoutDay(three, opts(180)))).toEqual([]);
    expect(chips(layoutDay(three, opts(165)))).toHaveLength(1);
  });

  test("once folding, each visible column is at least 64px wide", () => {
    expect(events(layoutDay(five(), opts(158))).map((item) => item.width)).toEqual([64, 64]);
  });
});

describe("placeDay, the vertical pass", () => {
  const place = (segments, colWidth = 200) => placeDay(layoutDay(segments, opts(colWidth)), { yOf: scale.yOf, minHeight: 20 });

  test("turns minutes into top and height", () => {
    const [item] = place([ev("a", 540, 600)]);
    expect(item).toMatchObject({ top: 468, height: 50 });
  });

  test("an overlaying event leaves the earlier title its lines", () => {
    const laid = place([ev("a", 540, 720, "Workshop"), ev("b", 630, 690, "Lunch")]);
    const a = laid.find((item) => item.id === "a");
    const b = laid.find((item) => item.id === "b");
    expect(b.top - a.top).toBeGreaterThanOrEqual(PAD_TOP + LINE_HEIGHT);
    expect(a.lineClamp).toBe(4);
    expect(a.hideTime).toBeUndefined();
  });

  test("a nested short event starts below its host's first line, and the host's time moves below it", () => {
    const laid = place([ev("a", 540, 780, "Workshop"), ev("b", 555, 570, "Standup")]);
    const a = laid.find((item) => item.id === "a");
    const b = laid.find((item) => item.id === "b");
    expect(b.top).toBe(a.top + PAD_TOP + LINE_HEIGHT + 3);
    expect(b.height).toBe(20);
    expect(a.lineClamp).toBe(1);
    expect(a.timeGap).toBe(24);
  });

  test("chips that touch or overlap merge into one", () => {
    const five = (start) => ["a", "b", "c", "d", "e"].map((id) => ev(`${id}${start}`, start, start + 60));
    const laid = place([...five(540), ...five(590)]);
    const merged = laid.filter((item) => item.chip);
    expect(merged).toHaveLength(1);
    expect(merged[0].hidden).toHaveLength(6);
  });
});

describe("review regressions", () => {
  const place = (segments, colWidth = 200) => placeDay(layoutDay(segments, opts(colWidth)), { yOf: scale.yOf, minHeight: 20 });
  const byId = (laid, id) => laid.find((item) => item.id === id);

  test("a short event nested in an event that folds behind the chip is placed without crashing", () => {
    const segments = [ev("a", 540, 780), ev("b", 540, 780), ev("c", 540, 780), ev("n", 560, 575)];
    const laid = place(segments, 100);
    const visible = new Set(events(laid).map((item) => item.id));
    const n = byId(laid, "n");
    expect(n).toBeDefined();
    expect(n.nestIn === null || visible.has(n.nestIn)).toBe(true);
  });

  test("a long event never joins a short event's nested group", () => {
    const laid = layoutDay([ev("L", 540, 900, "Focus"), ev("a", 540, 560, "Standup"), ev("z", 550, 880, "Offsite")], opts(200));
    expect(chips(laid)).toEqual([]);
    expect(byId(laid, "z")).toMatchObject({ level: 0, width: 100 });
    expect(byId(laid, "a").nestIn).toBe("L");
  });

  test("the fold ends where the crowd ends, and a long event is not hidden behind it", () => {
    const crowd = ["a", "b", "c", "d"].map((id) => ev(id, 540, 570));
    const laid = layoutDay([...crowd, ev("z", 550, 780, "Workshop")], opts(200));
    expect(events(laid).map((item) => item.id)).toContain("z");
    const [chip] = chips(laid);
    expect(chip).toMatchObject({ s: 540, e: 570 });
    expect(chip.hidden).toEqual(["b", "c", "d"]);
  });

  test("an overlay close enough to the earlier title drops that title's time line", () => {
    const laid = place([ev("a", 540, 720, "Workshop"), ev("b", 570, 690, "Lunch")]);
    expect(byId(laid, "b").level).toBe(1);
    expect(byId(laid, "a")).toMatchObject({ lineClamp: 1, hideTime: true });
  });

  test("a merged chip carries the warning when either side has one", () => {
    const five = (start, attention = []) => ["a", "b", "c", "d", "e"].map((id) => ev(`${id}${start}`, start, start + 60, id, { attention: attention.includes(id) }));
    const laid = place([...five(540), ...five(590, ["c", "d", "e"])]);
    const merged = chips(laid);
    expect(merged).toHaveLength(1);
    expect(merged[0].warn).toBe(true);
  });

  test("chips far apart stay separate", () => {
    const five = (start) => ["a", "b", "c", "d", "e"].map((id) => ev(`${id}${start}`, start, start + 60));
    expect(chips(place([...five(540), ...five(720)]))).toHaveLength(2);
  });

  test("layoutColumn defaults the minimum height to 20px", () => {
    const [item] = layoutColumn([ev("a", 540, 545)], opts(200));
    expect(item.height).toBe(20);
  });

  test("the output does not depend on the input order", () => {
    const segments = [
      ev("a", 540, 780, "Workshop"), ev("b", 555, 570, "Standup"), ev("c", 540, 600), ev("d", 545, 600),
      ev("e", 550, 620, "e", { attention: true }), ev("f", 600, 660), ev("g", 610, 640), ev("h", 720, 840),
    ];
    const forward = layoutColumn(segments, opts(160));
    expect(layoutColumn([...segments].reverse(), opts(160))).toEqual(forward);
    expect(layoutColumn([...segments.slice(4), ...segments.slice(0, 4)], opts(160))).toEqual(forward);
  });

  test("a chip draws above every event, however deep the cascade", () => {
    const cascade = Array.from({ length: 12 }, (_, i) => ev(`k${i}`, 480 + i * 30, 1200));
    const crowd = ["a", "b", "c", "d", "e"].map((id) => ev(id, 1100, 1160));
    const laid = layoutDay([...cascade, ...crowd], opts(400));
    const [chip] = chips(laid);
    expect(chip).toBeDefined();
    expect(chip.z).toBeGreaterThan(Math.max(...events(laid).map((item) => item.z)));
  });

  test("a column too narrow for one 64px column still keeps one column beside the chip", () => {
    const laid = layoutDay([ev("a", 540, 600), ev("b", 540, 600)], opts(80));
    expect(events(laid)).toHaveLength(1);
    expect(events(laid)[0].width).toBe(80 - CHIP_WIDTH);
  });

  test("whether a later event can overlay is measured in the earlier event's own column", () => {
    const laid = layoutDay([ev("A", 540, 720, "Quarterly planning"), ev("B", 545, 720, "x"), ev("g", 575, 700, "g")], opts(200));
    expect(byId(laid, "g").level).toBe(0);
  });

  test("a short event nested in an indented host starts inside the host", () => {
    const laid = layoutDay(
      [ev("A", 480, 720), ev("B", 540, 720), ev("C", 600, 720), ev("D", 660, 780), ev("E", 670, 690)],
      opts(200),
    );
    const d = byId(laid, "D");
    const e = byId(laid, "E");
    expect(e.nestIn).toBe("D");
    expect(e.left).toBeGreaterThan(d.left);
    expect(e.left + e.width).toBeLessThanOrEqual(200);
  });

  test("an event at the very end of the day stays inside the grid", () => {
    const [item] = place([ev("a", 1435, 1440)]);
    expect(item.top + item.height).toBeLessThanOrEqual(scale.yOf(1440));
  });

  test("a nested short event sits inside its host's own column, clear of the event sharing it", () => {
    const laid = place([ev("standup", 800, 920, "Standup"), ev("short", 810, 840, "Call"), ev("review", 825, 945, "Review")]);
    const host = byId(laid, "standup");
    const short = byId(laid, "short");
    expect(short.nestIn).toBe("standup");
    expect(short.left).toBeGreaterThan(host.left);
    expect(short.left + short.width).toBeLessThanOrEqual(host.left + host.width);
  });

  test("an overlay crossing a chip stops at the chip instead of running under it", () => {
    const crowd = ["a", "b", "c", "d", "e"].map((id) => ev(id, 540, 720));
    const laid = place([...crowd, ev("x", 660, 700, "Overlay")]);
    const [chip] = chips(laid);
    const x = byId(laid, "x");
    expect(x.left + x.width).toBeLessThanOrEqual(chip.left);
  });

  test("a staggered chain reuses the indent of events that have ended instead of folding", () => {
    const chain = Array.from({ length: 8 }, (_, i) => ev(`m${i}`, 480 + i * 30, 570 + i * 30, "Weekly sync"));
    const laid = layoutDay(chain, opts(200));
    expect(chips(laid)).toEqual([]);
    expect(byId(laid, "m3").left).toBe(0);
    expect(byId(laid, "m3").z).toBeGreaterThan(byId(laid, "m2").z);
  });

  test("a deep cascade on a narrow column keeps every event readable", () => {
    const deep = [ev("A", 480, 720), ev("B", 540, 720), ev("C", 600, 720), ev("D", 660, 720), ev("D2", 660, 720)];
    const laid = layoutDay(deep, opts(80));
    for (const item of events(laid)) expect(item.width).toBeGreaterThanOrEqual(24);
  });

  test("a short event nested in a host folded behind the chip stays clear of the chip", () => {
    const segments = [ev("x1", 555, 795, "x"), ev("o1", 585, 825, "1:1"), ev("st", 600, 840, "Standup"), ev("x2", 615, 645, "x"), ev("o2", 630, 645, "1:1")];
    const laid = place(segments, 80);
    const visible = events(laid);
    const ids = new Set(visible.map((item) => item.id));
    for (const chip of chips(laid)) {
      for (const item of visible.filter((v) => v.s < chip.e && v.e > chip.s)) expect(item.left).toBeLessThan(chip.left);
    }
    for (const item of visible) expect(item.nestIn === null || ids.has(item.nestIn)).toBe(true);
  });
});
