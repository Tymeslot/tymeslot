/**
 * A small parser for the calendar's stylesheets, shared by the CSS guards:
 * every style rule with the at-rules around it, a declaration's value, and
 * the z-index tokens in base/variables.css. Nesting is refused, so a nested
 * rule can never hide from a guard.
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const cssDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css");
export const read = (path) => readFileSync(resolve(cssDir, path), "utf8");
export const component = (name) => read(`components/${name}`);

// [{ at: ["@media (width < 40rem)"], selectors: [".a", ".b"], body: "..." }]
export function rules(source) {
  const text = source.replace(/\/\*[\s\S]*?\*\//g, "");
  const out = [];
  const stack = [];
  let buffer = "";

  for (const ch of text) {
    if (ch === "{") {
      const head = buffer.split(";").pop().trim();
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

export function decl(body, prop) {
  const match = body.match(new RegExp(`(?:^|;)\\s*${prop}\\s*:\\s*([^;]+)`));
  return match ? match[1].trim() : null;
}

export const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// True when the last compound of `selector` (what the rule styles) names `name`.
export function styles(selector, name) {
  let bare = selector;
  for (let prev = ""; prev !== bare; ) {
    prev = bare;
    bare = bare.replace(/:(?:has|not|is|where)\([^()]*\)/g, "");
  }
  const last = bare.split(/\s*[\s>+~]\s*/).pop();
  return new RegExp(`${escape(name)}(?![\\w-])`).test(last);
}

export const zOf = (rule) => {
  const value = decl(rule.body, "z-index");
  return value && value.replace(/\s*!important$/, "");
};

export const where = (list, name) => list.filter((r) => r.selectors.some((s) => styles(s, name)));

export function tokenValue(name) {
  const match = read("base/variables.css").match(new RegExp(`${escape(name)}\\s*:\\s*(\\d+)`));
  return match ? Number(match[1]) : NaN;
}
