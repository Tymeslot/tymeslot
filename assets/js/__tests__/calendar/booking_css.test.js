/**
 * Guards for the bookable layer's stylesheet: a band must never intercept a
 * click on the slot beneath it, and its label must sit above the events.
 */
import { describe, expect, test } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const dir = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css/components");
const read = (name) => readFileSync(resolve(dir, name), "utf8");

// Every declaration block whose selector list is exactly `selector`.
function blocks(css, selector) {
  return css
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("}")
    .map((chunk) => chunk.split("{"))
    .filter(([sel, body]) => body !== undefined && sel.trim() === selector)
    .map(([, body]) => body);
}

describe("calendar booking layer styles", () => {
  const both = read("calendar-surface.css") + "\n" + read("calendar-booking.css");

  test(".cal-bookable never takes pointer events", () => {
    const found = blocks(both, ".cal-bookable");
    expect(found.length).toBeGreaterThan(0);
    for (const body of found) expect(body).toMatch(/pointer-events:\s*none/);
  });

  test("the label is lifted above the events", () => {
    const [body] = blocks(read("calendar-booking.css"), ".cal-bookable-label");
    expect(body).toMatch(/z-index:\s*max\(calc\(var\(--cal-lift,\s*\d+\)\s*\+\s*1\),\s*3\)/);
  });

  test("the floating note keeps the surface's z-index and the disabled button keeps full opacity", () => {
    const booking = read("calendar-booking.css");
    for (const body of blocks(booking, ".cal-bookable-note")) expect(body).not.toMatch(/z-index/);
    expect(blocks(read("calendar-surface.css"), ".cal-bookable-note")[0]).toMatch(/z-index:\s*25/);
    const [disabled] = blocks(booking, ".cal-bookable-pop-button:disabled");
    expect(disabled).toMatch(/opacity:\s*1/);
    expect(disabled).toMatch(/color:\s*var\(--cal-text-muted\)/);
  });

  test("the hint stays muted", () => {
    expect(blocks(read("calendar-booking.css"), ".cal-bookable-pop-hint")[0]).toMatch(/--cal-text-muted/);
  });

  test("the label may extend below a short band", () => {
    const [body] = blocks(read("calendar-booking.css"), ".cal-bookable-label");
    expect(body).toMatch(/min-height:\s*20px/);
  });
});
