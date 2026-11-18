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
import { block, mockViewport, pushes, unmountAll } from "./canvas_harness.js";
import { commandSettings, commandStrings, mountWithBar, result } from "./command_fixtures.js";

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

  test("opened from a +N list, it closes the list and hands focus back to the list's anchor", () => {
    const { el, hook, input } = mountWithBar();
    hook.showList([hook.cache.events.get("event-1")], block(el, "event-1"), "Events at this time");
    press(document.activeElement, "k", { ctrlKey: true });
    expect(el.querySelector(".cal-list")).toBeNull();

    press(input, "Escape");

    expect(document.activeElement.dataset.eventId).toBe("event-1");
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

  test("a held Ctrl K is swallowed without changing the bar", () => {
    mountWithBar();
    const e = press(document.body, "k", { ctrlKey: true, repeat: true });
    expect(e.defaultPrevented).toBe(true);
    expect(isOpen()).toBe(false);
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

  test("Enter with no active row runs the first: the bar closes and the reveal goes to the row's date", () => {
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

  test("keys with focus outside the bar send it back to the input, and aria-expanded follows the rows", () => {
    const { hook, input, results } = mountWithBar();
    open();
    // The hook's own rows are there from the start; with none at all it reads "false".
    expect(input.getAttribute("aria-expanded")).toBe("true");
    hook.clearInstant();
    hook.syncActive();
    expect(input.getAttribute("aria-expanded")).toBe("false");
    results.innerHTML = result("event-1", "2026-10-21");
    press(input, "ArrowDown");
    expect(input.getAttribute("aria-expanded")).toBe("true");

    const outside = document.getElementById("outside-field");
    outside.focus();
    const e = press(outside, "Tab");

    expect(e.defaultPrevented).toBe(true);
    expect(document.activeElement).toBe(input);
  });

  test("a mousedown on the panel's dead space keeps focus; on the input it does not interfere", () => {
    const { bar, input } = mountWithBar();
    open();
    bar.querySelector("form").classList.add("cal-command-panel");
    const dead = new MouseEvent("mousedown", { bubbles: true, cancelable: true });
    bar.querySelector("form").dispatchEvent(dead);
    const onInput = new MouseEvent("mousedown", { bubbles: true, cancelable: true });
    input.dispatchEvent(onInput);
    expect(dead.defaultPrevented).toBe(true);
    expect(onInput.defaultPrevented).toBe(false);
  });

  test("Enter ignores server rows while a search is running", () => {
    const { hook, input, results } = mountWithBar();
    open();
    results.setAttribute("aria-busy", "true");
    results.innerHTML = result("event-1", "2026-10-21");
    press(input, "Enter");
    expect(isOpen()).toBe(true);
    expect(pushes(hook, "calendar:goto")).toEqual([]);

    results.setAttribute("aria-busy", "false");
    press(input, "Enter");
    expect(isOpen()).toBe(false);
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
  expect(css).toMatch(/height:\s*calc\(100dvh - var\(--cal-kb-inset, 0px\)\)/);
  expect(variables).toMatch(/--cal-z-command:\s*80;/);
});

const mockWide = (matches) => {
  window.matchMedia = (q) => ({ matches: q.includes("64rem") ? matches : false, media: q, addEventListener() {}, removeEventListener() {} });
};

describe("the hook's own rows", () => {
  const typeIn = (input, text) => {
    input.value = text;
    input.dispatchEvent(new Event("input", { bubbles: true }));
  };
  const mount = () => {
    const mounted = mountWithBar();
    mounted.hook.strings = { ...mounted.hook.strings, ...commandStrings };
    mounted.hook.settings = { ...mounted.hook.settings, ...commandSettings };
    press(document.body, "k", { ctrlKey: true });
    return mounted;
  };
  const rowLabels = (hook) => hook.commandRows().map((row) => row.querySelector(".cal-command-row-title")?.textContent ?? row.textContent);

  test("opening offers Today, New event, the views, the sets and the shortcuts, each with its key", () => {
    const { hook, bar } = mount();
    expect(rowLabels(hook)).toEqual(["Today", "New event", "Day", "3 days", "Week", "Month", "Agenda", "Switch to Work", "Switch to Personal", "Keyboard shortcuts"]);
    expect(bar.querySelector('[data-command-row="view-week"] kbd').textContent).toBe("W");
  });

  test("a typed date comes first, and a bare title's Add row comes last, after the search rows", () => {
    const { hook, input, results } = mount();
    typeIn(input, "20 oct");
    expect(rowLabels(hook)[0]).toBe("Go to Tue 20 Oct");

    results.innerHTML = result("event-1", "2026-10-21");
    typeIn(input, "Dentist");
    const rows = hook.commandRows();
    expect(rows.at(-2).id).toBe("calendar-command-row-event-1");
    expect(rows.at(-1).dataset.commandRow).toBe("add");
  });

  test("Enter on the date row goes there in the current view and leaves focus on the grid", () => {
    const { hook, el, input } = mount();
    typeIn(input, "20 oct");
    press(input, "Enter");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-20" }]);
    expect(el.contains(document.activeElement) || document.activeElement === el).toBe(true);
  });

  test("Add opens quick create filled in from the line, so one more Enter saves it", () => {
    const { hook, input } = mount();
    typeIn(input, "tomorrow 10:00 Dentist");
    expect(hook.commandRows()[0].dataset.commandRow).toBe("add");

    press(input, "Enter");

    expect(document.getElementById("calendar-command").hasAttribute("data-open")).toBe(false);
    expect(hook.quick).not.toBeNull();
    expect(hook.quickField().value).toBe("tomorrow 10:00 Dentist");
    expect(hook.draft.title).toBe("Dentist");
    expect(document.activeElement).toBe(hook.quickField());
  });

  test("a display command pushes its change to the surface", () => {
    const { hook, input } = mount();
    typeIn(input, "compact");
    press(input, "Enter");
    expect(pushes(hook, "calendar:set_density")).toEqual([{ option: "compact" }]);
  });

  test("a set command applies the set", () => {
    const { hook, input } = mount();
    typeIn(input, "work");
    press(input, "Enter");
    expect(pushes(hook, "calendar:apply_set")).toEqual([{ position: 1 }]);
  });

  test("focus mode is pushed to the dashboard, not the surface", () => {
    mockWide(true);
    const { hook, input } = mount();
    typeIn(input, "focus");
    press(input, "Enter");
    expect(hook.pushEvent).toHaveBeenCalledWith("calendar:toggle_focus", {});
    expect(pushes(hook, "calendar:toggle_focus")).toEqual([]);
  });

  test("on a phone focus mode is not offered", () => {
    mockViewport(true);
    const { hook, input } = mount();
    typeIn(input, "focus");
    expect(rowLabels(hook)).not.toContain("Focus mode");
  });

  test("a set's name is drawn escaped", () => {
    const { hook, input, bar } = mount();
    hook.settings = { ...hook.settings, sets: [{ position: 1, name: "<img src=x onerror=alert(1)>" }] };
    typeIn(input, "img");
    expect(bar.querySelector("img")).toBeNull();
    expect(bar.querySelector('[data-command-row="set-1"] .cal-command-row-title').textContent).toBe("Switch to <img src=x onerror=alert(1)>");
  });

  test("Add pushes no create event of its own", () => {
    const { hook, input } = mount();
    typeIn(input, "Dentist");
    press(input, "Enter");
    expect(hook.pushEvent.mock.calls).toEqual([]);
    expect(pushes(hook).filter((p) => /create|save/.test(p.event ?? ""))).toEqual([]);
  });

  test("Add hints at the time the draft would get, not at 09:00", () => {
    const { hook, input } = mount();
    typeIn(input, "Dentist tomorrow");
    const base = hook.nextDraft().base;
    expect(base).toBeDefined();
    const meta = hook.commandRows().find((row) => row.dataset.commandRow === "add").querySelector(".cal-command-row-meta").textContent;
    const hh = String(Math.floor(base.startMin / 60)).padStart(2, "0");
    expect(meta.endsWith(`${hh}:${String(base.startMin % 60).padStart(2, "0")}`)).toBe(true);
  });

  test("Today, Next period and Show all run", () => {
    const { hook, input } = mount();
    typeIn(input, "next period");
    press(input, "Enter");
    expect(pushes(hook, "calendar:goto")).toHaveLength(1);
    press(document.body, "k", { ctrlKey: true });
    typeIn(hook.commandField(), "show all");
    press(hook.commandField(), "Enter");
    expect(pushes(hook, "calendar:show_all")).toEqual([{}]);
  });

  test("Today goes to today's period", () => {
    const { hook, input } = mount();
    typeIn(input, "today");
    press(input, "Enter");
    expect(pushes(hook, "calendar:goto")).toHaveLength(1);
  });

  test("Import opens the importer, help the shortcuts", () => {
    const { hook, input } = mount();
    typeIn(input, "import");
    press(input, "Enter");
    expect(pushes(hook, "calendar:ics_open")).toEqual([{}]);

    press(document.body, "k", { ctrlKey: true });
    typeIn(hook.commandField(), "keyboard");
    press(hook.commandField(), "Enter");
    expect(pushes(hook, "calendar:toggle_menu")).toEqual([{ menu: "shortcuts" }]);
  });

  describe("desktop notifications", () => {
    afterEach(() => {
      delete global.Notification;
    });

    test("turning them on asks the browser inside the key press and pushes its answer", async () => {
      global.Notification = { permission: "default", requestPermission: vi.fn(() => Promise.resolve("denied")) };
      const { hook, input } = mount();
      typeIn(input, "notifications");
      press(input, "Enter");

      // Asked synchronously, before anything is awaited; the bar is closed.
      expect(global.Notification.requestPermission).toHaveBeenCalledTimes(1);
      expect(isOpen()).toBe(false);
      // Never the plain toggle, which would not wait for the browser.
      expect(pushes(hook, "calendar:toggle_desktop_reminders")).toEqual([]);
      await vi.waitFor(() => expect(pushes(hook, "calendar:enable_desktop_reminders")).toEqual([{ permission: "denied", source: "command" }]));
    });

    test("a browser without notifications is pushed as unsupported", async () => {
      const { hook, input } = mount();
      typeIn(input, "notifications");
      press(input, "Enter");
      await vi.waitFor(() => expect(pushes(hook, "calendar:enable_desktop_reminders")).toEqual([{ permission: "unsupported", source: "command" }]));
    });

    test("turning them off is the plain toggle and asks nothing", () => {
      global.Notification = { permission: "granted", requestPermission: vi.fn() };
      const { hook, input } = mount();
      hook.settings = { ...hook.settings, desktop_reminders: true };
      typeIn(input, "notifications");
      press(input, "Enter");
      expect(global.Notification.requestPermission).not.toHaveBeenCalled();
      expect(pushes(hook, "calendar:toggle_desktop_reminders")).toEqual([{}]);
      expect(pushes(hook, "calendar:enable_desktop_reminders")).toEqual([]);
    });
  });

  test("Leave the calendar set, while one is active", () => {
    const { hook, input } = mount();
    hook.settings = { ...hook.settings, active_set: 1 };
    typeIn(input, "leave the");
    press(input, "Enter");
    expect(pushes(hook, "calendar:apply_set")).toEqual([{ position: 0 }]);
  });

  test("focus mode is offered on a wide screen and not on a narrow one", () => {
    mockWide(false);
    let m = mount();
    typeIn(m.input, "focus");
    expect(rowLabels(m.hook)).not.toContain("Focus mode");
    unmountAll();
    mockWide(true);
    m = mount();
    typeIn(m.input, "focus");
    expect(rowLabels(m.hook)).toContain("Focus mode");
  });

  test("while a search is busy Enter does not fall to the Add row", () => {
    const { hook, input, results } = mount();
    typeIn(input, "zzqq");
    results.setAttribute("aria-busy", "true");
    hook.pushEvent.mockClear();
    press(input, "Enter");
    expect(document.getElementById("calendar-command").hasAttribute("data-open")).toBe(true);
    expect(hook.quick).toBeNull();
  });

  test("a view command switches the view on the current date", () => {
    const { hook, input } = mount();
    typeIn(input, "month");
    press(input, "Enter");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "month", date: "2026-10-14" }]);
  });

  test("a view command from a week without today opens the week's first day", () => {
    const { el, hook, input } = mount();
    el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
    typeIn(input, "agenda");
    press(input, "Enter");
    expect(pushes(hook, "calendar:goto").at(-1)).toEqual({ view: "agenda", date: "2026-10-19" });
  });
});
