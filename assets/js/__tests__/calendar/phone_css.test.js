/**
 * Guards for the calendar's z-index ladder and for the phone, views and
 * touch stylesheets. A sheet, a toast or the + button that slips off the
 * ladder ends up under something it must cover, and a phone rule that
 * escapes the phone query reshapes the desktop; no test of the markup can
 * see either. Tokens live in base/variables.css.
 */
import { describe, expect, test } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const cssDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css");
const read = (path) => readFileSync(resolve(cssDir, path), "utf8");
const component = (name) => read(`components/${name}`);

const CALENDAR = [
  "calendar-surface.css",
  "calendar-editing.css",
  "calendar-booking.css",
  "calendar-views.css",
  "calendar-phone.css",
  "calendar-touch.css",
];
const NEW = ["calendar-views.css", "calendar-phone.css", "calendar-touch.css"];
const PHONE = "(width < 40rem)";

// Every style rule with the at-rules around it:
// [{ at: ["@media (width < 40rem)"], selectors: [".a", ".b"], body: "..." }].
function rules(source) {
  const text = source.replace(/\/\*[\s\S]*?\*\//g, "");
  const out = [];
  const stack = [];
  let buffer = "";

  for (const ch of text) {
    if (ch === "{") {
      const head = buffer.split(";").pop().trim();
      // Nesting would hide a rule from this parser, so refuse it outright.
      if (stack.some((s) => !s.startsWith("@")) || head.includes("&")) {
        throw new Error(`CSS nesting is not supported by this guard: ${head}`);
      }
      stack.push(head);
      buffer = "";
    } else if (ch === "}") {
      const head = stack.pop();
      if (head && !head.startsWith("@")) {
        out.push({
          at: stack.filter((s) => s.startsWith("@")),
          selectors: head.split(",").map((s) => s.trim()),
          body: buffer,
        });
      }
      buffer = "";
    } else {
      buffer += ch;
    }
  }

  return out;
}

function decl(body, prop) {
  const match = body.match(new RegExp(`(?:^|;)\\s*${prop}\\s*:\\s*([^;]+)`));
  return match ? match[1].trim() : null;
}

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// True when the last compound of `selector` (what the rule styles) names
// `name`: `.cal-scroll[data-scroll]` names `.cal-scroll`; `.cal-scroll .x` does not.
function styles(selector, name) {
  // What sits inside :has(), :not(), :is() and :where() does not make the
  // rule style that element.
  let bare = selector;
  for (let prev = ""; prev !== bare; ) {
    prev = bare;
    bare = bare.replace(/:(?:has|not|is|where)\([^()]*\)/g, "");
  }
  const last = bare.split(/\s*[\s>+~]\s*/).pop();
  return new RegExp(`${escape(name)}(?![\\w-])`).test(last);
}

const zOf = (rule) => {
  const value = decl(rule.body, "z-index");
  return value && value.replace(/\s*!important$/, "");
};
const where = (list, name) => list.filter((r) => r.selectors.some((s) => styles(s, name)));

function tokenValue(name) {
  const match = read("base/variables.css").match(new RegExp(`${escape(name)}\\s*:\\s*(\\d+)`));
  return match ? Number(match[1]) : NaN;
}

describe("the calendar's z-index ladder", () => {
  test.each([
    ["calendar-surface.css", ".cal-list", "--cal-z-pop"],
    ["calendar-surface.css", ".cal-preview", "--cal-z-sheet"],
    ["calendar-surface.css", ".cal-bookable-pop", "--cal-z-pop"],
    ["calendar-booking.css", ".cal-bookable-pop", "--cal-z-pop"],
    ["calendar-editing.css", ".cal-qc", "--cal-z-sheet"],
    ["calendar-editing.css", ".cal-notice", "--cal-z-toast"],
  ])("%s: %s sits at %s", (file, selector, token) => {
    const found = rules(component(file)).filter((r) => r.selectors.includes(selector) && zOf(r));
    expect(found.length).toBeGreaterThan(0);
    for (const rule of found) expect(zOf(rule)).toBe(`var(${token})`);
  });

  test("no calendar stylesheet sets a literal z-index at or above the + button's", () => {
    // `.cal-panel` is absolute inside the surface row, an isolated stacking
    // context, so its 60 never meets the fixed overlays.
    const local = (file, rule) =>
      file === "calendar-editing.css" &&
      rule.selectors.length === 1 &&
      rule.selectors[0] === ".cal-panel" &&
      rule.at.includes("@media (width < 64rem)");

    const offenders = CALENDAR.filter((file) => existsSync(resolve(cssDir, "components", file))).flatMap((file) =>
      rules(component(file))
        .filter((rule) => /^\d+/.test(zOf(rule) || "") && Number(zOf(rule)) >= 45 && !local(file, rule))
        .map((rule) => `${file} ${rule.selectors.join(", ")}: ${zOf(rule)}`),
    );

    expect(offenders).toEqual([]);
  });

  test("the tokens keep their order around the dashboard nav and the core modal", () => {
    const modal = Number(read("modal.css").match(/\.modal-overlay[\s\S]*?z-\[(\d+)\]/)[1]);
    // The compact dashboard nav's inline z-index (dashboard_layout.ex).
    const nav = 50;
    const ladder = [
      tokenValue("--cal-z-fab"),
      nav,
      tokenValue("--cal-z-pop"),
      tokenValue("--cal-z-scrim"),
      tokenValue("--cal-z-sheet"),
      tokenValue("--cal-z-editor"),
      modal,
      tokenValue("--cal-z-toast"),
    ];

    expect(ladder.every(Number.isFinite)).toBe(true);
    expect([...ladder].sort((a, b) => a - b)).toEqual(ladder);
    expect(new Set(ladder).size).toBe(ladder.length);
  });

  test.each([
    [".cal-scrim", "--cal-z-scrim", true],
    [".cal-toast-region", "--cal-z-toast", true],
    [".is-sheet", "--cal-z-sheet", true],
    ["#calendar-fab", "--cal-z-fab", false],
    [".cal-fab", "--cal-z-fab", false],
  ])("%s takes %s wherever it sets a z-index", (name, token, required) => {
    const found = CALENDAR.filter((file) => existsSync(resolve(cssDir, "components", file)))
      .flatMap((file) => where(rules(component(file)), name))
      .filter(zOf);

    if (required) expect(found.length).toBeGreaterThan(0);
    expect(found.filter((rule) => zOf(rule) !== `var(${token})`).map((r) => r.selectors.join(", "))).toEqual([]);
  });

  test("the surface row rises to the sheet's layer for a sheet and to the editor's for the panel", () => {
    const phone = rules(component("calendar-phone.css"));
    const z = (selector) => phone.filter((r) => r.selectors.includes(selector)).map(zOf);

    expect(z(".cal-row:has(.is-sheet)")).toEqual(["var(--cal-z-sheet)"]);
    expect(z(".cal-row:has(.cal-panel)")).toEqual(["var(--cal-z-editor)"]);
  });
});

describe("the phone, views and touch stylesheets", () => {
  test.each(NEW)("%s exists and stays under 650 lines", (file) => {
    expect(existsSync(resolve(cssDir, "components", file))).toBe(true);
    expect(component(file).split("\n").length).toBeLessThanOrEqual(650);
  });

  test("every phone rule applies only under the phone query", () => {
    const tokensOnly = (body) =>
      body
        .split(";")
        .map((d) => d.trim())
        .filter(Boolean)
        .every((d) => d.startsWith("--"));

    const offenders = rules(component("calendar-phone.css"))
      .filter((r) => !r.at.some((a) => a.includes(PHONE)))
      .filter((r) => !tokensOnly(r.body))
      .map((r) => r.selectors.join(", "));

    expect(offenders).toEqual([]);
  });

  test("the phone breakpoint is spelt one way", () => {
    const queries = NEW.flatMap((file) => component(file).match(/@media[^{]*width[^{]*/g) || []).map((q) => q.trim());
    const others = queries
      .flatMap((q) => q.replace(/^@media\s*/, "").split(","))
      .flatMap((part) => part.match(/\(\s*[a-z-]*width[^)]*\)/g) || [])
      .filter((cond) => !/^\(width (<|>=) (40|64)rem\)$/.test(cond));

    expect(others).toEqual([]);
  });

  test("the toast moves above an open sheet by a marker the core modal really sets", () => {
    const phone = rules(component("calendar-phone.css"));
    // rules() splits selector lists at every comma, `:is(...)` included, so
    // each piece of the toast rule is checked on its own.
    const lifted = phone.filter((r) => r.selectors.some((s) => s.includes(".cal-sheet-open")) && decl(r.body, "top"));
    const modalSelectors = phone.flatMap((r) => r.selectors).filter((s) => s.includes(".modal-overlay"));

    expect(lifted.length).toBeGreaterThan(0);
    // <.modal> hides with an inline `display: none;`; it never sets a class.
    expect(modalSelectors.filter((s) => /\.modal-overlay:not\(\.hidden\)/.test(s))).toEqual([]);
    expect(modalSelectors.filter((s) => !/\.modal-overlay\[style\*="display: flex"\]/.test(s))).toEqual([]);
  });

  test("the grid's floating note is lifted to the + button's top edge and its Show button is a touch target", () => {
    const phone = rules(component("calendar-phone.css")).filter((r) => r.at.some((a) => a.includes(PHONE)));
    const note = where(phone, ".cal-bookable-note").find((r) => decl(r.body, "bottom"));
    const show = where(phone, ".cal-bookable-show").find((r) => decl(r.body, "min-height"));

    expect(note && decl(note.body, "bottom")).toBe("var(--cal-fab-clear)");
    expect(show && decl(show.body, "min-height")).toBe("2.75rem");
  });

  test("touch: the grid pans vertically, the handle takes every touch, events never call out", () => {
    const touch = rules(component("calendar-touch.css"));
    const sets = (name, prop, wanted) => where(touch, name).some((r) => wanted.test(decl(r.body, prop) || ""));

    expect(sets(".cal-scroll", "touch-action", /^pan-y$/)).toBe(true);
    expect(sets("[data-touch-handle]", "touch-action", /^none$/)).toBe(true);
    expect(sets(".cal-ev", "-webkit-touch-callout", /^none$/)).toBe(true);
  });

  test.each(NEW)("%s: every transition and animation has a reduced-motion answer", (file) => {
    const list = rules(component(file));
    const moves = (body) =>
      /(?:^|;)\s*(transition|transition-duration|animation|animation-name)\s*:\s*(?!none|0s)/.test(body);
    const stills = (body) => /(?:^|;)\s*(?:transition|animation|transform)\s*:\s*none\b/.test(body);
    const calmed = new Set(
      list
        .filter((r) => r.at.some((a) => a.includes("prefers-reduced-motion: reduce")) && stills(r.body))
        .flatMap((r) => r.selectors),
    );

    const offenders = list
      .filter((r) => !r.at.some((a) => a.includes("prefers-reduced-motion")))
      .filter((r) => moves(r.body))
      .flatMap((r) => r.selectors)
      .filter((s) => !calmed.has(s));

    expect(offenders).toEqual([]);
  });

  test.each(NEW)("%s: colours come from tokens and heights from dynamic viewport units", (file) => {
    const bodies = rules(component(file)).map((r) => r.body).join("\n");

    expect(bodies.match(/#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(/g)).toBeNull();
    expect(bodies.match(/100vh/g)).toBeNull();
  });

  test("the phone chrome pads the safe areas", () => {
    const phone = component("calendar-phone.css");

    expect(phone).toMatch(/env\(safe-area-inset-bottom\)/);
    expect(phone).toMatch(/env\(safe-area-inset-top\)/);
  });

  test.each([".cal-agenda", ".cal-month-agenda", ".cal-scroll"])(
    "%s leaves room under the + button on a phone",
    (name) => {
      const found = where(rules(component("calendar-phone.css")), name).filter(
        (r) => r.at.some((a) => a.includes(PHONE)) && decl(r.body, "padding-bottom") === "var(--cal-fab-clear)",
      );

      expect(found.length).toBeGreaterThan(0);
    },
  );

  test("--cal-fab-clear clears the + button and its offset", () => {
    expect(read("base/variables.css")).toMatch(/--cal-fab-clear:\s*calc\(var\(--cal-fab-size\) \+ 1\.5rem\)/);
  });
});
