/**
 * Guards for calendar-power.css: the command bar and the drop overlay sit
 * on their rungs of the z-index ladder, the bar is hidden until opened and
 * becomes a sheet only under the phone query, and every motion it adds has
 * a reduced-motion answer. Task 19 adds a case here for each rule its
 * browser check fixed.
 */
import { describe, expect, test } from "vitest";
import { component, decl, read, rules, tokenValue, where, zOf } from "./css_rules.js";

const POWER = "calendar-power.css";
const PHONE = "(width < 40rem)";
const REDUCED = "(prefers-reduced-motion: reduce)";
const NO_PREFERENCE = "(prefers-reduced-motion: no-preference)";
const power = () => rules(component(POWER));

describe("calendar-power.css", () => {
  test("stays within its 400-line budget", () => {
    expect(component(POWER).split("\n").length).toBeLessThanOrEqual(400);
  });

  test("the command bar and its scrim take --cal-z-command wherever they set a z-index", () => {
    const found = [...where(power(), ".cal-command"), ...where(power(), ".cal-command-scrim")].filter(zOf);
    expect(found.length).toBeGreaterThan(0);
    expect(found.filter((r) => zOf(r) !== "var(--cal-z-command)").map((r) => r.selectors.join(", "))).toEqual([]);
  });

  test("the drop overlay takes --cal-z-drop wherever it sets a z-index", () => {
    const found = where(power(), "#calendar-drop-overlay").filter(zOf);
    expect(found.filter((r) => zOf(r) !== "var(--cal-z-drop)").map((r) => r.selectors.join(", "))).toEqual([]);
  });

  test("sets no literal z-index", () => {
    const literal = power().filter((r) => /^\d/.test(zOf(r) || ""));
    expect(literal.map((r) => `${r.selectors.join(", ")}: ${zOf(r)}`)).toEqual([]);
  });

  test("the new tokens keep their place in the ladder", () => {
    const modal = Number(read("modal.css").match(/\.modal-overlay[\s\S]*?z-\[(\d+)\]/)[1]);
    const ladder = [
      tokenValue("--cal-z-fab"),
      tokenValue("--cal-z-drop"),
      tokenValue("--cal-z-pop"),
      tokenValue("--cal-z-sheet"),
      tokenValue("--cal-z-editor"),
      tokenValue("--cal-z-command"),
      modal,
      tokenValue("--cal-z-toast"),
    ];
    expect(ladder.every(Number.isFinite)).toBe(true);
    expect([...ladder].sort((a, b) => a - b)).toEqual(ladder);
  });

  test("the command bar is hidden until it is opened", () => {
    const top = power().filter((r) => r.at.length === 0);
    const closed = top.filter((r) => r.selectors.includes(".cal-command:not([data-open])"));
    const others = top.filter((r) => r.selectors.some((s) => s.startsWith(".cal-command")) && !r.selectors.includes(".cal-command:not([data-open])"));
    expect(closed.map((r) => decl(r.body, "display"))).toContain("none");
    expect(others.map((r) => decl(r.body, "display")).filter((d) => d === "none")).toEqual([]);
  });

  test("the full-height command sheet lives only under the phone query", () => {
    const sheetRules = power().filter((r) => r.selectors.some((s) => s.includes(".cal-command")) && /100dvh/.test(r.body));
    expect(sheetRules.length).toBeGreaterThan(0);
    const outside = sheetRules.filter((r) => !r.at.some((a) => a.includes(PHONE)) && r.selectors.every((s) => !s.includes("scrim")));
    expect(outside.map((r) => r.selectors.join(", "))).toEqual([]);
  });

  test("every transition or animation has a reduced-motion answer", () => {
    const all = power();
    const reduced = all.filter((r) => r.at.some((a) => a.includes(REDUCED)));
    // Motion written inside `(prefers-reduced-motion: no-preference)` (as Task 14 does) already answers it.
    const answered = (r) => r.at.some((a) => a.includes(REDUCED) || a.includes(NO_PREFERENCE));
    const moving = all.filter((r) => !answered(r) && (decl(r.body, "transition") || decl(r.body, "animation")));
    const stilled = (selector) =>
      reduced.some(
        (r) =>
          r.selectors.includes(selector) &&
          (/^none/.test(decl(r.body, "transition") || "") || /^none/.test(decl(r.body, "animation") || "")),
      );
    expect(moving.flatMap((r) => r.selectors).filter((s) => !stilled(s))).toEqual([]);
  });
});
