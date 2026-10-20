/**
 * Tests for the command bar's hook half (hooks/calendar_canvas/command.js):
 * Ctrl K, Cmd K and / open it, Ctrl K and Escape close it and hand focus
 * back, the arrows move through its rows, Enter and a click run one, Tab
 * stays inside, and a LiveView patch never loses the active row.
 */
import { afterEach, describe, expect, test, vi } from "vitest";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { pushes, unmountAll } from "./canvas_harness.js";
import { mountWithBar, result } from "./command_fixtures.js";

const cssDir = resolve(dirname(fileURLToPath(import.meta.url)), "../../../css");

const press = (target, key, extra = {}) => {
  const e = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra });
  target.dispatchEvent(e);
  return e;
};
const click = (el) => el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
const tick = () => new Promise((done) => setTimeout(done, 0));

const isOpen = () => document.getElementById("calendar-command").hasAttribute("data-open");

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
});

describe("opening and closing", () => {
  test("Ctrl K opens the bar and focuses its input, even from a text field", () => {
    const { input } = mountWithBar();
    const field = document.getElementById("outside-field");
    field.focus();

    const e = press(field, "k", { ctrlKey: true });

    expect(isOpen()).toBe(true);
    expect(e.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(input);
  });

  test("Cmd K opens it too; with Shift or Alt held neither does", () => {
    mountWithBar();
    press(document.body, "k", { ctrlKey: true, shiftKey: true });
    press(document.body, "k", { metaKey: true, altKey: true });
    expect(isOpen()).toBe(false);

    press(document.body, "k", { metaKey: true });
    expect(isOpen()).toBe(true);
  });

  test("/ opens it, but not while typing in a field", () => {
    mountWithBar();
    press(document.getElementById("outside-field"), "/");
    expect(isOpen()).toBe(false);

    press(document.body, "/");
    expect(isOpen()).toBe(true);
  });

  test("Ctrl K again closes it and hands focus back", () => {
    const { input } = mountWithBar();
    const field = document.getElementById("outside-field");
    field.focus();
    press(field, "k", { ctrlKey: true });

    press(input, "k", { ctrlKey: true });

    expect(isOpen()).toBe(false);
    expect(document.activeElement).toBe(field);
  });

  test("Escape closes it, hands focus back, and nothing else on the page sees that Escape", () => {
    const { hook, bar, input } = mountWithBar();
    const field = document.getElementById("outside-field");
    field.focus();
    press(field, "k", { ctrlKey: true });
    const later = vi.fn();
    document.addEventListener("keydown", later);

    press(input, "Escape");
    document.removeEventListener("keydown", later);

    expect(isOpen()).toBe(false);
    expect(document.activeElement).toBe(field);
    expect(later).not.toHaveBeenCalled();
    expect(hook.liveSocket.execJS).toHaveBeenLastCalledWith(bar, "hide");
  });

  test("with nothing focused before, closing focuses the toolbar's search button", () => {
    const { input } = mountWithBar();
    press(document.body, "k", { ctrlKey: true });
    press(input, "Escape");
    expect(document.activeElement).toBe(document.getElementById("calendar-search"));
  });

  test("the search buttons' calendar:command-open opens it", () => {
    const { el } = mountWithBar();
    el.dispatchEvent(new CustomEvent("calendar:command-open"));
    expect(isOpen()).toBe(true);
  });

  test("Ctrl K does nothing during a drag or over an open core modal, but a closed one is no obstacle", () => {
    const { hook } = mountWithBar();
    hook.drag = { id: "event-1" };
    press(document.body, "k", { ctrlKey: true });
    expect(isOpen()).toBe(false);
    hook.drag = null;

    document.body.insertAdjacentHTML("beforeend", `<div id="open-modal" class="modal-overlay" style="display: flex;"></div>`);
    press(document.body, "k", { ctrlKey: true });
    expect(isOpen()).toBe(false);

    document.getElementById("open-modal").style.display = "none";
    press(document.body, "k", { ctrlKey: true });
    expect(isOpen()).toBe(true);
  });

  test("Ctrl K over quick create cancels it and opens the bar", () => {
    const { hook } = mountWithBar();
    hook.quickCreateNext();
    expect(hook.quick).not.toBeNull();

    press(document.activeElement, "k", { ctrlKey: true });

    expect(hook.quick).toBeNull();
    expect(hook.draft).toBeNull();
    expect(isOpen()).toBe(true);
  });

  test("opening over rows a closed bar still holds asks the server to clear them", () => {
    const { hook, results } = mountWithBar();
    results.innerHTML = result("event-1", "2026-10-21");

    press(document.body, "k", { ctrlKey: true });

    expect(pushes(hook, "calendar:command_query")).toEqual([{ q: "" }]);
  });
});

describe("rows", () => {
  // From Task 15 the bar draws its own rows on opening; these tests are about
  // the server's rows, so the hook's two groups are emptied after it opens.
  const open = () => {
    press(document.body, "k", { ctrlKey: true });
    for (const id of ["calendar-command-instant", "calendar-command-after"]) {
      const group = document.getElementById(id);
      if (group) group.innerHTML = "";
    }
  };

  test("Up and Down move through the rows and wrap, marking the active one", () => {
    const { input, results } = mountWithBar();
    open();
    results.innerHTML = result("event-1", "2026-10-21") + result("event-2", "2026-10-22");

    press(input, "ArrowDown");
    expect(input.getAttribute("aria-activedescendant")).toBe("calendar-command-row-event-1");
    press(input, "ArrowDown");
    press(input, "ArrowDown");
    expect(input.getAttribute("aria-activedescendant")).toBe("calendar-command-row-event-1");
    press(input, "ArrowUp");

    expect(input.getAttribute("aria-activedescendant")).toBe("calendar-command-row-event-2");
    expect(document.getElementById("calendar-command-row-event-2").getAttribute("aria-selected")).toBe("true");
    expect(document.getElementById("calendar-command-row-event-1").getAttribute("aria-selected")).toBe("false");
  });

  test("Home and End jump to the first and the last row", () => {
    const { input, results } = mountWithBar();
    open();
    results.innerHTML = result("event-1", "2026-10-21") + result("event-2", "2026-10-22") + result("event-3", "2026-10-23");

    press(input, "End");
    expect(input.getAttribute("aria-activedescendant")).toBe("calendar-command-row-event-3");
    press(input, "Home");
    expect(input.getAttribute("aria-activedescendant")).toBe("calendar-command-row-event-1");
  });

  test("a patch that drops the marks gets them back", async () => {
    const { input, results } = mountWithBar();
    open();
    results.innerHTML = result("event-1", "2026-10-21");
    press(input, "ArrowDown");

    input.removeAttribute("aria-activedescendant");
    document.getElementById("calendar-command-row-event-1").removeAttribute("aria-selected");
    await tick();

    expect(input.getAttribute("aria-activedescendant")).toBe("calendar-command-row-event-1");
    expect(document.getElementById("calendar-command-row-event-1").getAttribute("aria-selected")).toBe("true");
  });

  test("Enter with no active row runs the first: the bar closes and the grid goes to the row's date", () => {
    const { hook, input, results } = mountWithBar();
    open();
    results.innerHTML = result("event-1", "2026-10-21");

    const e = press(input, "Enter");

    expect(e.defaultPrevented).toBe(true);
    expect(isOpen()).toBe(false);
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-21" }]);
  });

  test("a click on a row runs it; a click on the scrim only closes", () => {
    const { hook, bar, results } = mountWithBar();
    open();
    click(bar.querySelector("[data-command-scrim]"));
    expect(isOpen()).toBe(false);
    expect(pushes(hook, "calendar:goto")).toEqual([]);

    open();
    results.innerHTML = result("event-1", "2026-10-28");
    click(document.getElementById("calendar-command-row-event-1"));
    expect(isOpen()).toBe(false);
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-28" }]);
  });

  test("Tab and Shift Tab stay inside the bar", () => {
    const { bar, input } = mountWithBar();
    open();
    const close = bar.querySelector("[data-command-close]");

    press(input, "Tab");
    expect(document.activeElement).toBe(close);
    press(close, "Tab");
    expect(document.activeElement).toBe(input);
    press(input, "Tab", { shiftKey: true });
    expect(document.activeElement).toBe(close);
  });
});

test("the stylesheet keeps the bar closed until data-open, above sheets and below core modals", () => {
  const css = readFileSync(resolve(cssDir, "components/calendar-power.css"), "utf8");
  const variables = readFileSync(resolve(cssDir, "base/variables.css"), "utf8");

  expect(css).toMatch(/\.cal-command:not\(\[data-open\]\)\s*\{\s*display:\s*none;/);
  expect(css).toMatch(/\.cal-command\s*\{[^}]*z-index:\s*var\(--cal-z-command\)/);
  expect(variables).toMatch(/--cal-z-command:\s*80;/);
});
