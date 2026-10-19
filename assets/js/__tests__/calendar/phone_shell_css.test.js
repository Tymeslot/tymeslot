/**
 * Guards for the phone shell's stylesheet (css/components/calendar-phone.css):
 * the rules that keep the first paint right on a phone without any script.
 */
import { describe, expect, test } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const cssRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css");
const read = (path) => readFileSync(resolve(cssRoot, path), "utf8");
const stripComments = (css) => css.replace(/\/\*[\s\S]*?\*\//g, "");

// The bodies of every `@media <query>` block in `css`, joined.
export function mediaRules(css, query) {
  const source = stripComments(css);
  const bodies = [];
  let from = 0;
  for (;;) {
    const start = source.indexOf(`@media ${query}`, from);
    if (start < 0) break;
    const open = source.indexOf("{", start);
    let depth = 0;
    let index = open;
    for (; index < source.length; index++) {
      if (source[index] === "{") depth++;
      else if (source[index] === "}" && --depth === 0) break;
    }
    bodies.push(source.slice(open + 1, index));
    from = index + 1;
  }
  return bodies.join("\n");
}

// Every flat declaration block whose selector list, whitespace collapsed, is `selector`.
export function blocks(css, selector) {
  return stripComments(css)
    .split("}")
    .map((chunk) => chunk.split("{"))
    .filter(([sel, body]) => body !== undefined && sel.replace(/\s+/g, " ").trim() === selector)
    .map(([, body]) => body);
}

const phone = () => mediaRules(read("components/calendar-phone.css"), "(width < 40rem)");

describe("the phone shell", () => {
  test("app.css loads the phone rules after the calendar's other stylesheets", () => {
    const app = read("app.css");
    const at = (name) => app.indexOf(`@import "./components/${name}"`);
    expect(at("calendar-phone.css")).toBeGreaterThan(at("calendar-booking.css"));
    expect(at("calendar-phone.css")).toBeGreaterThan(at("calendar-views.css"));
    expect(at("calendar-views.css")).toBeGreaterThan(-1);
  });

  test("a skeleton is never wider than three columns on a phone", () => {
    const [cap] = blocks(phone(), ".cal-skeleton:has(> .cal-skeleton-col:nth-child(4))");
    expect(cap).toMatch(/grid-template-columns:\s*repeat\(3,\s*minmax\(0,\s*1fr\)\)/);
    const [hide] = blocks(phone(), ".cal-skeleton-col:nth-child(n + 4)");
    expect(hide).toMatch(/display:\s*none/);
  });
});
