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

describe("the z-index ladder", () => {
  const variables = read("base/variables.css");
  const z = (name) => {
    const match = variables.match(new RegExp(`${name}:\\s*(\\d+);`));
    expect(match, `${name} is defined`).not.toBeNull();
    return Number(match[1]);
  };
  const coreModal = Number(read("modal.css").match(/z-\[(\d+)\]/)[1]);

  test("the toast sits above core modals, which hold two of the phone's sheets", () => {
    expect(z("--cal-z-toast")).toBeGreaterThan(coreModal);
  });

  test("the editor covers sheets, sheets cover their scrim, the scrim covers popovers", () => {
    expect(z("--cal-z-editor")).toBeGreaterThan(z("--cal-z-sheet"));
    expect(z("--cal-z-sheet")).toBeGreaterThan(z("--cal-z-scrim"));
    expect(z("--cal-z-scrim")).toBeGreaterThan(z("--cal-z-pop"));
  });

  test("the + button stays under the dashboard's top bar (z 50) and every overlay", () => {
    expect(z("--cal-z-fab")).toBeLessThan(50);
    expect(z("--cal-z-fab")).toBeLessThan(z("--cal-z-pop"));
  });

  test("the keyboard inset has a default, so a page without the hook still lays out", () => {
    expect(variables).toMatch(/--cal-kb-inset:\s*0px;/);
  });
});

describe("toasts on every screen", () => {
  test("the toast region and the hook's notice use the toast token", () => {
    const [region] = blocks(read("components/calendar-editing.css"), ".cal-toast-region");
    expect(region).toMatch(/position:\s*fixed/);
    expect(region).toMatch(/z-index:\s*var\(--cal-z-toast\)/);
    const notice = blocks(read("components/calendar-editing.css"), ".cal-notice");
    expect(notice.length).toBeGreaterThan(0);
    for (const body of notice) expect(body).toMatch(/z-index:\s*var\(--cal-z-toast\)/);
  });

  test("on a phone toasts rise above the tabs and the + button", () => {
    const [body] = blocks(phone(), ".cal-toast-region, .cal-notice");
    expect(body).toMatch(/bottom:\s*calc\(var\(--cal-tabs-h\)\s*\+\s*env\(safe-area-inset-bottom\)\s*\+\s*5\.5rem\)/);
  });

  test("on a phone toasts move to the top while a sheet, the preview or the editor is open", () => {
    const selector =
      ':root.cal-sheet-open :is(.cal-toast-region, .cal-notice), :root:has(#calendar-panel, #calendar-preview, .modal-overlay[style*="display: flex"]) :is(.cal-toast-region, .cal-notice)';
    const [body] = blocks(phone(), selector);
    expect(body).toMatch(/top:\s*calc\(env\(safe-area-inset-top\)\s*\+\s*0\.5rem\)/);
    expect(body).toMatch(/bottom:\s*auto/);
  });
});

describe("the tabs and the + button", () => {
  test("the tab bar clears the home indicator", () => {
    const [body] = blocks(phone(), ".cal-tabs");
    expect(body).toMatch(/padding-bottom:\s*env\(safe-area-inset-bottom\)/);
    expect(body).toMatch(/min-height:\s*calc\(var\(--cal-tabs-h\)\s*\+\s*env\(safe-area-inset-bottom\)\)/);
  });

  test("the + button floats above the tab bar's end, on its own layer", () => {
    const [body] = blocks(phone(), ".cal-fab");
    expect(body).toMatch(/position:\s*fixed/);
    expect(body).toMatch(/bottom:\s*calc\(var\(--cal-tabs-h\)\s*\+\s*env\(safe-area-inset-bottom\)\s*\+\s*1rem\)/);
    expect(body).toMatch(/z-index:\s*var\(--cal-z-fab\)/);
    expect(body).toMatch(/width:\s*var\(--cal-fab-size\)/);
  });
});

describe("the Calendars sheet", () => {
  test("its checkboxes are 44px targets on a phone", () => {
    const [body] = blocks(phone(), '.cal-sheet-list [role="checkbox"]');
    expect(body).toMatch(/min-width:\s*2\.75rem/);
    expect(body).toMatch(/min-height:\s*2\.75rem/);
  });
});

describe("the Calendars sheet's density control", () => {
  test("its buttons are 44px tall on a phone", () => {
    const [body] = blocks(phone(), "#calendar-sheet-density button");
    expect(body).toMatch(/min-height:\s*2\.75rem/);
  });
});
