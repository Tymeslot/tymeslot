/**
 * Tests for the CalendarCanvas hook's power keys
 * (hooks/calendar_canvas/power_keys.js): T, J and K, the guard they share
 * with the other single-key shortcuts, and the overlays that silence every
 * one of them (MODALS). Today is Wednesday 14 October 2026.
 */
import { afterEach, describe, expect, test, vi } from "vitest";
import { powerKeyName } from "../../hooks/calendar_canvas/power_keys.js";
import { mockViewport, mountHook, payload, pushes, settings, unmountAll } from "./canvas_harness.js";

const press = (target, key, extra = {}) => target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra }));
const gotos = (hook) => pushes(hook, "calendar:goto");
const monthPayload = () => payload({ view: "month", range: { from: "2026-08-31", to: "2026-12-07" } });

afterEach(() => {
  unmountAll();
  vi.restoreAllMocks();
});

describe("J and K", () => {
  test("J steps to the next week and K to the previous one, with focus anywhere on the page", () => {
    const { hook } = mountHook();

    press(document.body, "j");
    expect(gotos(hook)).toEqual([{ view: "week", date: "2026-10-21" }]);

    press(document.body, "k");
    expect(gotos(hook).at(-1)).toEqual({ view: "week", date: "2026-10-14" });
  });

  test("a second J before the server answers steps on from the first", () => {
    const { hook } = mountHook();

    press(document.body, "j");
    press(document.body, "j");

    expect(gotos(hook)).toEqual([
      { view: "week", date: "2026-10-21" },
      { view: "week", date: "2026-10-28" },
    ]);
  });

  test("the grid draws the next week at once from the cache", () => {
    const { el } = mountHook();

    press(document.body, "j");

    expect(el.querySelector('[data-goto-day="2026-10-21"]')).not.toBeNull();
    expect(el.getAttribute("aria-busy")).toBe("false");
  });

  test("on a phone they step three days", () => {
    mockViewport(true);
    const { hook } = mountHook(payload({ view: "three_day" }));

    press(document.body, "j");

    expect(gotos(hook)).toEqual([{ view: "three_day", date: "2026-10-17" }]);
  });

  test("in month view they step a month", () => {
    const { hook } = mountHook(monthPayload());

    press(document.body, "j");
    press(document.body, "k");
    press(document.body, "k");

    expect(gotos(hook).map((g) => g.date)).toEqual(["2026-11-14", "2026-10-14", "2026-09-14"]);
    expect(gotos(hook).every((g) => g.view === "month")).toBe(true);
  });
});

describe("T", () => {
  test("goes back to this week from another one", () => {
    const { hook } = mountHook();

    press(document.body, "j");
    press(document.body, "t");

    expect(gotos(hook).at(-1)).toEqual({ view: "week", date: "2026-10-14" });
  });

  test("on a phone it goes back to today in the three-day view", () => {
    mockViewport(true);
    const { hook } = mountHook(payload({ view: "three_day" }));

    press(document.body, "j");
    press(document.body, "t");

    expect(gotos(hook).at(-1)).toEqual({ view: "three_day", date: "2026-10-14" });
  });

  test("stays in month view", () => {
    const { hook } = mountHook(monthPayload());

    press(document.body, "k");
    press(document.body, "T");

    expect(gotos(hook).at(-1)).toEqual({ view: "month", date: "2026-10-14" });
  });
});

describe("what the keys leave alone", () => {
  test.each([
    ["Ctrl K", "k", { ctrlKey: true }],
    ["Cmd K", "k", { metaKey: true }],
    ["Shift J", "J", { shiftKey: true }],
    ["a held J", "j", { repeat: true }],
    ["Alt T", "t", { altKey: true }],
  ])("%s does nothing", (_name, key, extra) => {
    const { hook } = mountHook();

    press(document.body, key, extra);

    expect(gotos(hook)).toEqual([]);
  });

  test("a J typed in a text field stays in the field", () => {
    const { hook } = mountHook();
    const input = document.createElement("input");
    document.body.append(input);
    input.focus();

    press(input, "j");

    expect(gotos(hook)).toEqual([]);
  });

  test("J does nothing while quick create is open", () => {
    const { hook } = mountHook();
    press(document.body, "c");
    expect(document.getElementById("calendar-quick-create")).not.toBeNull();

    press(document.body, "j");

    expect(gotos(hook)).toEqual([]);
  });

  test("destroyed removes the key listener", () => {
    const { hook } = mountHook();
    const remove = vi.spyOn(document, "removeEventListener");

    hook.destroyed();

    expect(remove).toHaveBeenCalledWith("keydown", hook.powerKeyListener);
  });
});

describe("overlays that take the keyboard", () => {
  test.each([
    ["the open command bar", '<div id="calendar-command" data-open="true"></div>'],
    ["an open core modal", '<div class="modal-overlay" style="display: flex;"></div>'],
    ["the shortcut help", '<div id="calendar-shortcuts"></div>'],
  ])("%s silences J and the view letters", (_name, html) => {
    const { hook } = mountHook();
    document.body.insertAdjacentHTML("beforeend", html);

    press(document.body, "j");
    press(document.body, "d");

    expect(gotos(hook)).toEqual([]);
  });

  test.each([
    ["C opens no quick create", "c", {}, () => expect(document.getElementById("calendar-quick-create")).toBeNull()],
    ["B toggles no bookable layer", "b", {}, (hook) => expect(pushes(hook, "calendar:bookable_toggle")).toEqual([])],
    ["Ctrl Z asks for no undo", "z", { ctrlKey: true }, (hook) => expect(pushes(hook, "calendar:undo")).toEqual([])],
  ])("an open core modal silences the older single keys: %s", (_name, key, extra, expectSilent) => {
    const { hook } = mountHook();
    document.body.insertAdjacentHTML("beforeend", '<div class="modal-overlay" style="display: flex;"></div>');

    press(document.body, key, extra);

    expectSilent(hook);
  });

  test("a closed command bar and a hidden core modal leave them working", () => {
    const { hook } = mountHook();
    document.body.insertAdjacentHTML("beforeend", '<div id="calendar-command"></div><div class="modal-overlay" style="display: none;"></div>');

    press(document.body, "d");

    expect(gotos(hook)).toEqual([{ view: "day", date: "2026-10-14" }]);
  });
});

describe("F: focus mode", () => {
  const press = (key, extra = {}, target = document.body) =>
    target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra }));
  let restore = null;

  // Answers the wide query (1024px and up) with `wide`, every other query no.
  const stubWidth = (wide) => {
    const had = Object.prototype.hasOwnProperty.call(window, "matchMedia");
    const original = window.matchMedia;
    window.matchMedia = vi.fn((query) => ({
      matches: query === "(width >= 64rem)" ? wide : false,
      media: query,
      addEventListener() {},
      removeEventListener() {},
    }));
    restore = () => {
      if (had) window.matchMedia = original;
      else delete window.matchMedia;
    };
  };

  const mountWithPush = () => {
    const mounted = mountHook();
    mounted.hook.pushEvent = vi.fn();
    return mounted;
  };

  afterEach(() => {
    unmountAll();
    restore?.();
    restore = null;
  });

  test("F asks the dashboard to toggle focus mode on a wide screen", () => {
    stubWidth(true);
    const { hook } = mountWithPush();
    press("f");
    expect(hook.pushEvent).toHaveBeenCalledWith("calendar:toggle_focus", {});
  });

  test("F does nothing below 1024px, where focus mode changes nothing", () => {
    stubWidth(false);
    const { hook } = mountWithPush();
    press("f");
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  test.each([
    ["Shift", { shiftKey: true }],
    ["Ctrl (the browser's find)", { ctrlKey: true }],
    ["Cmd", { metaKey: true }],
  ])("F does nothing with %s", (_name, extra) => {
    stubWidth(true);
    const { hook } = mountWithPush();
    press(extra.shiftKey ? "F" : "f", extra);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });

  test("F is the field's own letter in an input", () => {
    stubWidth(true);
    const { hook } = mountWithPush();
    const input = document.createElement("input");
    document.body.appendChild(input);
    press("f", {}, input);
    expect(hook.pushEvent).not.toHaveBeenCalled();
  });
});

describe("0 to 9: calendar sets", () => {
  const press = (key, extra = {}, target = document.body) =>
    target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra }));
  const withSets = (active_set) =>
    payload({ settings: { ...settings, sets: [{ position: 1, name: "Work" }, { position: 3, name: "Family" }], active_set } });
  const live = () => document.getElementById("calendar-live").textContent;

  afterEach(() => unmountAll());

  test("a set's digit applies it and says so", () => {
    const { hook } = mountHook(withSets(0));
    press("3");
    expect(pushes(hook, "calendar:apply_set")).toEqual([{ position: 3 }]);
    expect(live()).toBe("Showing the Family set");
  });

  test("a digit with no set, or the active set's own, does nothing", () => {
    const { hook } = mountHook(withSets(1));
    press("2");
    press("1");
    expect(pushes(hook, "calendar:apply_set")).toEqual([]);
  });

  test("0 leaves the active set, and does nothing with none active", () => {
    const { hook } = mountHook(withSets(1));
    press("0");
    expect(pushes(hook, "calendar:apply_set")).toEqual([{ position: 0 }]);
    expect(live()).toBe("Calendar set turned off");
    unmountAll();

    const idle = mountHook(withSets(0));
    press("0");
    expect(pushes(idle.hook, "calendar:apply_set")).toEqual([]);
  });

  test.each([
    ["Ctrl", { ctrlKey: true }],
    ["Alt", { altKey: true }],
  ])("digits do nothing with %s", (_name, extra) => {
    const { hook } = mountHook(withSets(0));
    press("1", extra);
    expect(pushes(hook, "calendar:apply_set")).toEqual([]);
  });

  test("a digit typed with Shift applies its set (the AZERTY number row)", () => {
    const { hook } = mountHook(withSets(0));
    press("1", { shiftKey: true });
    expect(pushes(hook, "calendar:apply_set")).toEqual([{ position: 1 }]);
  });

  test("a digit typed in a field stays the field's", () => {
    const { hook } = mountHook(withSets(0));
    const input = document.createElement("input");
    document.body.appendChild(input);
    press("1", {}, input);
    expect(pushes(hook, "calendar:apply_set")).toEqual([]);
  });

  test("powerKeyName maps letters, digits and ? and nothing else", () => {
    const key = (k, extra = {}) => new KeyboardEvent("keydown", { key: k, ...extra });
    expect(powerKeyName(key("T"))).toBe("t");
    expect(powerKeyName(key("T", { shiftKey: true }))).toBeNull();
    expect(powerKeyName(key("7"))).toBe("7");
    expect(powerKeyName(key("7", { shiftKey: true }))).toBe("7");
    expect(powerKeyName(key("7", { code: "Numpad7" }))).toBe("7");
    expect(powerKeyName(key("?", { shiftKey: true }))).toBe("?");
    expect(powerKeyName(key("Enter"))).toBeNull();
    // `/` belongs to the command bar (Task 14), never to this table.
    expect(powerKeyName(key("/"))).toBeNull();
    expect(powerKeyName(key("+"))).toBeNull();
  });
});

describe("calendar:focus", () => {
  afterEach(() => unmountAll());

  test("focuses the first listed control that is on screen", () => {
    const { handlers } = mountHook();
    const [rail, sheet] = ["calendar-rail-new-set", "calendar-sheet-new-set"].map((id) => {
      const button = document.createElement("button");
      button.id = id;
      document.body.appendChild(button);
      return button;
    });
    rail.getClientRects = () => [];
    sheet.getClientRects = () => [{}];

    handlers["calendar:focus"]({ ids: [rail.id, sheet.id, "missing"] });

    expect(document.activeElement).toBe(sheet);
    rail.remove();
    sheet.remove();
  });
});

describe("?: shortcut help", () => {
  const press = (key, extra = {}, target = document.body) =>
    target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra }));

  afterEach(() => unmountAll());

  test("? asks the surface for the help (Shift is how it is typed)", () => {
    const { hook } = mountHook();
    press("?", { shiftKey: true });
    expect(pushes(hook, "calendar:toggle_menu")).toEqual([{ menu: "shortcuts" }]);
  });

  test("? does nothing while the help, or any calendar modal, is open", () => {
    const { hook } = mountHook();
    const help = document.createElement("div");
    help.id = "calendar-shortcuts";
    document.body.appendChild(help);
    press("?", { shiftKey: true });
    expect(pushes(hook, "calendar:toggle_menu")).toEqual([]);
  });

  test("? typed in a field stays the field's", () => {
    const { hook } = mountHook();
    const input = document.createElement("input");
    document.body.appendChild(input);
    press("?", { shiftKey: true }, input);
    expect(pushes(hook, "calendar:toggle_menu")).toEqual([]);
  });
});
