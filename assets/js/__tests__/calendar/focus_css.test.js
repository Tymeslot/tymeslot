/**
 * Guards for focus mode's rules in css/components/dashboard.css: from the
 * lg breakpoint (64rem) the dashboard menu and the row's gutter go; below
 * it nothing changes, since the menu is a drawer there.
 */
import { expect, test } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const cssRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css");
const css = readFileSync(resolve(cssRoot, "components/dashboard.css"), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

// [start, end) of every `@media <query> { ... }` block, braces included.
function mediaRanges(source, query) {
  const ranges = [];
  let from = 0;
  for (;;) {
    const start = source.indexOf(`@media ${query}`, from);
    if (start < 0) return ranges;
    let index = source.indexOf("{", start);
    let depth = 0;
    for (; index < source.length; index++) {
      if (source[index] === "{") depth++;
      else if (source[index] === "}" && --depth === 0) break;
    }
    ranges.push([start, index + 1]);
    from = index + 1;
  }
}

const wideRanges = mediaRanges(css, "(width >= 64rem)");
const wide = wideRanges.map(([start, end]) => css.slice(start, end)).join("\n");
const outsideWide = wideRanges.reduceRight((text, [start, end]) => text.slice(0, start) + text.slice(end), css);

test("from 64rem focus mode hides the dashboard menu", () => {
  expect(wide).toMatch(/#dashboard-root\[data-calendar-focus\]\s+#dashboard-sidebar\s*\{\s*display:\s*none;?\s*\}/);
});

test("from 64rem focus mode drops the gutter beside the menu", () => {
  expect(wide).toMatch(/#dashboard-root\[data-calendar-focus\]\s+\.dashboard-main-row\s*\{\s*gap:\s*0;?\s*\}/);
});

test("from 64rem focus mode hides the strips above the grid", () => {
  expect(wide).toMatch(/#dashboard-root\[data-calendar-focus\]\s+#calendar-strips\s*>\s*\*\s*\{\s*display:\s*none;?\s*\}/);
});

test("below 64rem focus mode changes nothing", () => {
  expect(outsideWide).not.toMatch(/data-calendar-focus/);
});
