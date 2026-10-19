/**
 * Guards for the phone's sheets and full-screen editor in
 * calendar-phone.css (and quick create's touch rules in
 * calendar-editing.css): what jsdom cannot lay out, read from the
 * stylesheets themselves, as booking_css.test.js does.
 */
import { describe, expect, test } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const dir = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css/components");
const read = (name) => readFileSync(resolve(dir, name), "utf8").replace(/\/\*[\s\S]*?\*\//g, "");

// The bodies of every `@media <query>` block in `css`, braces matched.
function mediaBodies(css, query) {
  const bodies = [];
  let from = 0;
  for (;;) {
    const at = css.indexOf(`@media ${query}`, from);
    if (at < 0) return bodies;
    let i = css.indexOf("{", at) + 1;
    const start = i;
    let depth = 1;
    while (depth > 0 && i < css.length) {
      if (css[i] === "{") depth += 1;
      else if (css[i] === "}") depth -= 1;
      i += 1;
    }
    bodies.push(css.slice(start, i - 1));
    from = i;
  }
}

// Every declaration block in flat `css` whose selector list is `selector`
// (whitespace normalised), joined.
function rule(css, selector) {
  const found = css
    .split("}")
    .map((chunk) => chunk.split("{"))
    .filter(([sel, body]) => body !== undefined && sel.replace(/\s+/g, " ").trim() === selector)
    .map(([, body]) => body);
  expect(found.length, `no rule for ${selector}`).toBeGreaterThan(0);
  return found.join("\n");
}

const phone = () => mediaBodies(read("calendar-phone.css"), "(width < 40rem)").join("\n");

describe("phone sheets", () => {
  test("the scrim covers the screen just under the sheets", () => {
    const body = rule(phone(), ".cal-scrim");
    expect(body).toMatch(/position:\s*fixed/);
    expect(body).toMatch(/inset:\s*0/);
    expect(body).toMatch(/z-index:\s*var\(--cal-z-scrim\)/);
  });

  test("the list, quick create, the explainer and the preview lie across the foot, above the keyboard and the home indicator", () => {
    const body = rule(phone(), ".cal-list.is-sheet, .cal-qc.is-sheet, .cal-bookable-pop.is-sheet, .cal-preview");
    expect(body).toMatch(/bottom:\s*var\(--cal-kb-inset,\s*0px\)/);
    expect(body).toMatch(/left:\s*0/);
    expect(body).toMatch(/right:\s*0/);
    expect(body).toMatch(/top:\s*auto/);
    expect(body).toMatch(/z-index:\s*var\(--cal-z-sheet\)/);
    expect(body).toMatch(/max-height:\s*calc\(100dvh - var\(--cal-kb-inset,\s*0px\)/);
    expect(body).toMatch(/padding-bottom:\s*calc\([^;]*env\(safe-area-inset-bottom\)/);
  });

  test("the surface row is lifted while it holds a sheet, above the + button", () => {
    expect(rule(phone(), ".cal-row:has(.is-sheet)")).toMatch(/z-index:\s*var\(--cal-z-sheet\)/);
  });

  test("the grid leaves room to scroll a late draft above a sheet", () => {
    expect(rule(phone(), ":root:has(.cal-qc.is-sheet) .cal-scroll")).toMatch(/padding-bottom:\s*50dvh/);
  });
});
