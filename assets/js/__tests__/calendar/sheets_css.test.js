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

describe("phone full-screen editor", () => {
  test("the panel covers the screen and its foot follows the keyboard", () => {
    const body = rule(phone(), ".cal-panel");
    expect(body).toMatch(/position:\s*fixed/);
    expect(body).toMatch(/inset:\s*0 0 var\(--cal-kb-inset,\s*0px\) 0/);
    expect(body).toMatch(/z-index:\s*var\(--cal-z-editor\)/);
    expect(body).toMatch(/width:\s*auto/);
    expect(body).toMatch(/max-width:\s*none/);
    expect(body).toMatch(/padding-bottom:\s*env\(safe-area-inset-bottom\)/);
    expect(body).toMatch(/padding-left:\s*env\(safe-area-inset-left\)/);
    expect(body).toMatch(/padding-right:\s*env\(safe-area-inset-right\)/);
  });

  test("the surface row is lifted over the dashboard's nav while the panel is open", () => {
    expect(rule(phone(), ".cal-row:has(.cal-panel)")).toMatch(/z-index:\s*var\(--cal-z-editor\)/);
  });

  test("the header clears the notch and its controls are 44px", () => {
    expect(rule(phone(), ".cal-panel-head")).toMatch(/padding-top:\s*max\(0\.5rem,\s*env\(safe-area-inset-top\)\)/);
    const controls = rule(phone(), ".cal-panel-head .icon-button");
    expect(controls).toMatch(/min-width:\s*44px/);
    expect(controls).toMatch(/min-height:\s*44px/);
  });

  test("every button in the panel is 44px high and its fields never make iOS zoom", () => {
    expect(rule(phone(), '.cal-panel button:not([role="switch"], #calendar-panel-guests li button)')).toMatch(/min-height:\s*44px/);
    expect(rule(phone(), ".cal-panel :is(input, select, textarea)")).toMatch(/font-size:\s*var\(--font-size-base\)/);
  });

  test("the preview sheet's actions are thumb-sized", () => {
    expect(rule(phone(), ".cal-preview :is(button, a)")).toMatch(/min-height:\s*44px/);
    expect(rule(phone(), ".cal-preview .icon-button")).toMatch(/min-width:\s*44px/);
  });
});

describe("phone full-screen editor, small controls", () => {
  test("switches and guest remove buttons keep their size", () => {
    const body = rule(phone(), '.cal-panel button:not([role="switch"], #calendar-panel-guests li button)');
    expect(body).toMatch(/min-height:\s*44px/);
  });

  test("a guest remove button has a centred 44px hit area", () => {
    expect(rule(phone(), "#calendar-panel-guests li button")).toMatch(/position:\s*relative/);
    const hit = rule(phone(), "#calendar-panel-guests li button::before");
    expect(hit).toMatch(/width:\s*44px/);
    expect(hit).toMatch(/height:\s*44px/);
  });

  test("segmented buttons and weekday chips are 44px wide", () => {
    expect(rule(phone(), '.cal-panel [role="group"] button, .cal-preview [role="group"] button')).toMatch(/min-width:\s*44px/);
    const chip = rule(phone(), ".cal-panel #calendar-panel-repeat-custom label");
    expect(chip).toMatch(/min-width:\s*44px/);
    expect(chip).toMatch(/min-height:\s*44px/);
  });
});

describe("quick create on touch", () => {
  test("on a phone the chips and buttons are 44px and the chips' text is readable", () => {
    const chips = rule(phone(), ".cal-qc-chip");
    expect(chips).toMatch(/min-height:\s*44px/);
    expect(chips).toMatch(/font-size:\s*var\(--font-size-sm\)/);
    expect(rule(phone(), ".cal-qc-native.is-open")).toMatch(/min-height:\s*44px/);
    expect(rule(phone(), "span.cal-qc-chip")).toMatch(/line-height:\s*40px/);
    expect(rule(phone(), ".cal-qc-seg button, .cal-qc-more, .cal-qc-save")).toMatch(/min-height:\s*44px/);
  });

  test("on a phone the select and the native inputs never make iOS zoom", () => {
    expect(rule(phone(), ".cal-qc-calendar select, .cal-qc-native, .cal-qc-native.is-open")).toMatch(/font-size:\s*var\(--font-size-base\)/);
    // No other phone rule may give the shown input the chips' 14px.
    const small = phone().split("}").filter((chunk) => /font-size:\s*var\(--font-size-sm\)/.test(chunk));
    for (const chunk of small) expect(chunk.split("{")[0]).not.toMatch(/cal-qc-native/);
  });

  test("on a coarse pointer the native date and time inputs take the tap themselves", () => {
    const coarse = mediaBodies(read("calendar-editing.css"), "(pointer: coarse)").join("\n");
    const body = rule(coarse, ".cal-qc-native");
    expect(body).toMatch(/pointer-events:\s*auto/);
    expect(body).toMatch(/font-size:\s*var\(--font-size-base\)/);
  });
});
