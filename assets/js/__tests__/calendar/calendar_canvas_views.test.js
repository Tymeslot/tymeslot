/**
 * Tests for month and agenda in the CalendarCanvas hook
 * (hooks/calendar_canvas/views.js): drawing both from the cache, their
 * clicks and keys, the agenda's load-more, the view letters, and C outside
 * the time grid. Today is Wednesday 14 October 2026.
 */
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { block, event, mockViewport, mountHook, payload, pushes, settings, unmountAll } from "./canvas_harness.js";
import { formatWall } from "../../calendar/time.js";

const press = (target, key, extra = {}) => target.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...extra }));
const click = (el) => el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
const monthPayload = (overrides = {}) => payload({ view: "month", range: { from: "2026-08-31", to: "2026-12-07" }, ...overrides });
const agendaPayload = (overrides = {}) => payload({ view: "agenda", range: { from: "2026-09-16", to: "2026-12-09" }, ...overrides });
const tall = (el, hook) => {
  Object.defineProperty(el, "clientHeight", { value: 628, configurable: true });
  hook.render();
};

// jsdom has no IntersectionObserver; this one is triggered by hand.
class FakeObserver {
  static last = null;
  constructor(callback, options) {
    this.callback = callback;
    this.options = options;
    this.target = null;
    FakeObserver.last = this;
  }
  observe(target) {
    this.target = target;
  }
  disconnect() {
    this.target = null;
  }
}
const reachEnd = () => FakeObserver.last.callback([{ isIntersecting: true, target: FakeObserver.last.target }]);
const replyTo = (hook, name) => hook.pushEventTo.mock.calls.filter(([, pushed]) => pushed === name).at(-1)[3];

beforeEach(() => {
  FakeObserver.last = null;
  vi.stubGlobal("IntersectionObserver", FakeObserver);
});

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe("month", () => {
  test("draws six weeks of days with the events as chips", () => {
    const { el, hook } = mountHook(monthPayload());
    tall(el, hook);

    expect(el.querySelectorAll("button[data-month-day]")).toHaveLength(42);
    expect(el.querySelector('[data-month-day="2026-10-14"]').getAttribute("aria-current")).toBe("date");
    expect(el.querySelector('.cal-mchip[data-event-id="event-1"]')).not.toBeNull();
    expect(el.getAttribute("aria-busy")).toBe("false");
  });

  test("a chip opens the event's preview", () => {
    const { el, hook } = mountHook(monthPayload());
    tall(el, hook);
    click(el.querySelector('.cal-mchip[data-event-id="event-1"]'));
    expect(pushes(hook, "calendar:open")).toEqual([{ id: "event-1" }]);
  });

  test("a day opens in Day view, drawn at once from the cache", () => {
    const { el, hook } = mountHook(monthPayload());
    click(el.querySelector('[data-month-day="2026-10-15"]'));

    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-15" }]);
    expect(el.querySelector('.cal-col[data-day="2026-10-15"]')).not.toBeNull();
  });

  test("a click on a day's empty space opens it too", () => {
    const { el, hook } = mountHook(monthPayload());
    click(el.querySelector('[data-month-cell="2026-10-20"]'));
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-20" }]);
  });

  test("a day too full for its cell keeps the rest behind +N, which lists the day", () => {
    const { el } = mountHook(monthPayload());
    const more = el.querySelector('[data-month-more="2026-10-14"]');
    expect(more.textContent).toBe("+2");
    expect(el.querySelector('.cal-mchip[data-event-id="event-3"]')).not.toBeNull();

    click(more);

    const list = el.querySelector(".cal-list");
    expect(list.getAttribute("aria-label")).toBe("Wed 14 Oct");
    expect([...list.querySelectorAll("[data-event-id]")].map((b) => b.dataset.eventId)).toEqual(["event-1", "event-2"]);
  });

  test("arrow keys, Home and End move between days with one tab stop", () => {
    const { el } = mountHook(monthPayload());
    const wed = el.querySelector('[data-month-day="2026-10-14"]');
    wed.focus();

    press(wed, "ArrowDown");
    expect(document.activeElement.dataset.monthDay).toBe("2026-10-21");
    expect(document.activeElement.tabIndex).toBe(0);
    expect(wed.tabIndex).toBe(-1);

    press(document.activeElement, "End");
    expect(document.activeElement.dataset.monthDay).toBe("2026-10-25");
  });

  test("the focused day keeps its focus and its tab stop through the minute's redraw", () => {
    const { el, hook } = mountHook(monthPayload());
    const wed = el.querySelector('[data-month-day="2026-10-14"]');
    wed.focus();
    press(wed, "ArrowRight");

    hook.render();

    expect(document.activeElement.dataset.monthDay).toBe("2026-10-15");
    expect(el.querySelectorAll('button[data-month-day][tabindex="0"]')).toHaveLength(1);
  });
});

describe("agenda", () => {
  test("lists the days with events from its date, today marked", () => {
    const { el } = mountHook(agendaPayload());

    expect([...el.querySelectorAll("[data-agenda-day]")].map((d) => d.dataset.agendaDay)).toEqual(["2026-10-14", "2026-10-15"]);
    expect(el.querySelector('[data-agenda-day="2026-10-14"] [aria-current="date"]')).not.toBeNull();
    expect(el.querySelector('.cal-agenda button[data-event-id="event-3"]')).not.toBeNull();
  });

  test("a row opens the event's preview", () => {
    const { el, hook } = mountHook(agendaPayload());
    click(el.querySelector('.cal-agenda [data-event-id="event-2"]'));
    expect(pushes(hook, "calendar:open")).toEqual([{ id: "event-2" }]);
  });

  test("its end asks for the next weeks, once, and draws them when they come", () => {
    const { el, hook } = mountHook(agendaPayload());
    expect(FakeObserver.last.target).toBe(el.querySelector("[data-agenda-sentinel]"));

    reachEnd();
    reachEnd();

    expect(pushes(hook, "calendar:agenda_more")).toEqual([{ through: "2026-12-08" }]);

    replyTo(hook, "calendar:agenda_more")({
      done: false,
      payload: {
        view: "agenda",
        date: "2026-10-14",
        range: { from: "2026-12-09", to: "2027-01-06" },
        now: "2026-10-14T08:30",
        reset: false,
        settings,
        events: [event("event-9", "Christmas lunch", "2026-12-15T12:00", "2026-12-15T13:00")],
      },
    });

    expect(el.querySelector('.cal-agenda [data-event-id="event-9"]')).not.toBeNull();
    reachEnd();
    expect(pushes(hook, "calendar:agenda_more").at(-1)).toEqual({ through: "2027-01-05" });
  });

  test("keeps its scroll position when it redraws", () => {
    // jsdom has no layout: each element remembers the scrollTop it was given.
    const tops = new WeakMap();
    vi.spyOn(HTMLElement.prototype, "scrollTop", "get").mockImplementation(function () {
      return tops.get(this) ?? 0;
    });
    vi.spyOn(HTMLElement.prototype, "scrollTop", "set").mockImplementation(function (value) {
      tops.set(this, value);
    });
    const { el, hook } = mountHook(agendaPayload());
    el.querySelector("[data-view-scroll]").scrollTop = 120;
    hook.render();
    expect(el.querySelector("[data-view-scroll]").scrollTop).toBe(120);
  });

  test("once the server is done, Show later moves the date on", () => {
    const { el, hook } = mountHook(agendaPayload());
    reachEnd();
    replyTo(hook, "calendar:agenda_more")({ done: true, payload: null });

    expect(el.querySelector("[data-agenda-sentinel]")).toBeNull();
    click(el.querySelector("[data-agenda-later]"));

    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "agenda", date: "2027-03-31" }]);
  });

  test("a payload for another view or date is ignored", () => {
    const { el, hook } = mountHook(agendaPayload());
    reachEnd();
    const stray = (extra) => ({
      done: false,
      payload: { view: "agenda", date: "2026-10-14", range: { from: "2026-12-09", to: "2027-01-06" }, now: "2026-10-14T08:30", reset: false, settings, events: [event("event-9", "Stray", "2026-12-15T12:00", "2026-12-15T13:00")], ...extra },
    });

    replyTo(hook, "calendar:agenda_more")(stray({ date: "2026-11-02" }));
    expect(el.querySelector('[data-event-id="event-9"]')).toBeNull();
    expect(hook.cache.events.has("event-9")).toBe(false);

    reachEnd();
    replyTo(hook, "calendar:agenda_more")(stray({ view: "week" }));
    expect(hook.cache.events.has("event-9")).toBe(false);
  });

  test("an answer for an agenda the organiser has left is kept, not drawn", () => {
    const { el, hook } = mountHook(agendaPayload());
    reachEnd();
    press(document.body, "w");

    replyTo(hook, "calendar:agenda_more")({
      done: false,
      payload: { view: "agenda", date: "2026-10-14", range: { from: "2026-12-09", to: "2027-01-06" }, now: "2026-10-14T08:30", reset: false, settings, events: [] },
    });

    expect(el.querySelector(".cal-agenda")).toBeNull();
    expect(el.querySelector(".cal-grid")).not.toBeNull();
  });
});

describe("view letters", () => {
  test.each([
    ["d", "day"],
    ["x", "three_day"],
    ["m", "month"],
    ["A", "agenda"],
  ])("%s switches to %s, keeping the date", (key, view) => {
    const { hook } = mountHook();
    press(document.body, key);
    expect(pushes(hook, "calendar:goto")).toEqual([{ view, date: "2026-10-14" }]);
  });

  test("W goes back to the week", () => {
    const { hook } = mountHook(monthPayload());
    press(document.body, "w");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-14" }]);
  });

  test("the view already shown stays as it is", () => {
    const { hook } = mountHook();
    press(document.body, "w");
    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test.each([
    ["Ctrl", { ctrlKey: true }],
    ["Cmd", { metaKey: true }],
    ["Alt", { altKey: true }],
    ["a repeating key", { repeat: true }],
  ])("does nothing with %s", (_name, extra) => {
    const { hook } = mountHook();
    press(document.body, "m", extra);
    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("is the field's own letter in an input, and the dialog's in a dialog", () => {
    const { hook } = mountHook();
    const input = document.createElement("input");
    const dialog = document.createElement("div");
    dialog.setAttribute("role", "dialog");
    const inside = document.createElement("button");
    dialog.appendChild(inside);
    document.body.append(input, dialog);

    press(input, "m");
    press(inside, "a");

    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("M on a focused event that can move starts the keyboard move instead", () => {
    const { el, hook } = mountHook();
    const target = block(el, "event-1");
    target.focus();

    press(target, "m");

    expect(pushes(hook, "calendar:goto")).toEqual([]);
    expect(hook.moving?.id).toBe("event-1");
  });

  test("D on a focused event still switches to Day view", () => {
    const { el, hook } = mountHook();
    const target = block(el, "event-1");
    target.focus();
    press(target, "d");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-14" }]);
  });
});

test("C in month opens quick create on the month's date, without leaving month", () => {
  const { el, hook } = mountHook(monthPayload({ date: "2026-11-10", range: { from: "2026-09-01", to: "2027-01-31" } }));

  press(document.body, "c");

  expect(document.getElementById("calendar-quick-create")).not.toBeNull();
  expect(formatWall(hook.draft.start)).toBe("2026-11-10T09:00");
  expect(pushes(hook, "calendar:goto")).toEqual([]);
  expect(el.querySelector(".cal-month")).not.toBeNull();
});

// Agenda from Wednesday 7 October; quick create's chips read the draft.
const popover = () => document.getElementById("calendar-quick-create");
const chipDate = () => popover().querySelector('[data-qc-input="date"]').value;
const chipStart = () => popover().querySelector('[data-qc-pick="start"]').textContent;

test("in agenda the + button opens quick create within the week from the agenda's date", () => {
  const { el } = mountHook(payload({ view: "agenda", date: "2026-10-07", range: { from: "2026-09-09", to: "2026-12-02" } }));
  el.dispatchEvent(new CustomEvent("calendar:quick-create", { bubbles: true }));

  expect(chipDate()).toBe("2026-10-07");
  expect(chipStart()).toBe("09:00");
});

test("outside the time grid a typed day elsewhere moves the draft but not the period", () => {
  vi.useFakeTimers();
  const { hook } = mountHook(monthPayload({ date: "2026-10-20" }));
  press(document.body, "c");
  const field = document.getElementById("calendar-qc-field");
  field.value = "Review 27/12";
  field.dispatchEvent(new Event("input", { bubbles: true }));

  vi.advanceTimersByTime(400);

  expect(chipDate()).toBe("2026-12-27");
  expect(pushes(hook, "calendar:goto")).toEqual([]);
  expect(popover()).not.toBeNull();
});

describe("agenda loading across view changes", () => {
  const more = (extra = {}) => ({
    done: false,
    payload: { view: "agenda", date: "2026-10-14", range: { from: "2026-12-09", to: "2027-01-06" }, now: "2026-10-14T08:30", reset: false, settings, events: [], ...extra },
  });

  test("a stray payload re-arms the observer, so loading goes on", () => {
    const { hook } = mountHook(agendaPayload());
    reachEnd();
    const before = FakeObserver.last;

    replyTo(hook, "calendar:agenda_more")(more({ date: "2026-11-02" }));

    expect(FakeObserver.last).not.toBe(before);
    expect(hook.agendaBusy()).toBe(false);
  });

  test("done with a stray payload does not end the agenda", () => {
    const { el, hook } = mountHook(agendaPayload());
    reachEnd();
    replyTo(hook, "calendar:agenda_more")({ ...more({ date: "2026-11-02" }), done: true });
    expect(el.querySelector("[data-agenda-sentinel]")).not.toBeNull();
  });

  test("done for an agenda the organiser has since moved on from does not end this one", () => {
    const { el, hook } = mountHook(agendaPayload());
    reachEnd();
    hook.navigate({ view: "agenda", date: "2026-10-15" });
    replyTo(hook, "calendar:agenda_more")({ done: true, payload: null });
    expect(el.querySelector("[data-agenda-sentinel]")).not.toBeNull();
  });

  test("a late reply does not clear a newer request's busy flag", () => {
    vi.useFakeTimers();
    const { hook } = mountHook(agendaPayload());
    reachEnd();
    const first = replyTo(hook, "calendar:agenda_more");
    vi.advanceTimersByTime(10_001);
    reachEnd();
    expect(pushes(hook, "calendar:agenda_more")).toHaveLength(2);

    first({ done: false, payload: null });

    expect(hook.agendaBusy()).toBe(true);
  });

  test("the observer is disconnected on leaving the agenda and on unmount", () => {
    const { hook } = mountHook(agendaPayload());
    const observer = FakeObserver.last;
    expect(observer.target).not.toBeNull();
    press(document.body, "w");
    hook.navigate({ view: "week", date: "2026-10-14" });
    expect(observer.target).toBeNull();

    const second = mountHook(agendaPayload());
    const next = FakeObserver.last;
    expect(next.target).not.toBeNull();
    second.hook.destroyed();
    expect(next.target).toBeNull();
  });

  test("the minute's redraw keeps focus on the copy of a multi-day event in its own day", () => {
    const { el, hook } = mountHook(agendaPayload({ events: [event("night", "Night shift", "2026-10-14T20:00", "2026-10-15T08:00")] }));
    const rows = el.querySelectorAll('[data-event-id="night"]');
    expect(rows).toHaveLength(2);
    rows[1].focus();

    hook.render();

    expect(document.activeElement.dataset.eventId).toBe("night");
    expect(document.activeElement.closest("[data-agenda-day]").dataset.agendaDay).toBe("2026-10-15");
  });
});

describe("month focus and chips", () => {
  test("another date starts the tab stop afresh", () => {
    const { el, hook } = mountHook(monthPayload());
    const wed = el.querySelector('[data-month-day="2026-10-14"]');
    wed.focus();
    press(wed, "ArrowRight");

    hook.navigate({ view: "month", date: "2026-10-20" });

    expect(el.querySelector('button[data-month-day][tabindex="0"]').dataset.monthDay).toBe("2026-10-20");
  });

  test("chips carry their day, so a redraw finds the right copy", () => {
    const { el } = mountHook(monthPayload());
    expect(el.querySelector('.cal-mchip[data-event-id="event-3"]').dataset.day).toBe("2026-10-15");
  });
});

describe("view letters, more cases", () => {
  test("M on a focused agenda row is the row's key, not the month view", () => {
    const { el, hook } = mountHook(agendaPayload());
    const row = el.querySelector('.cal-agenda button[data-event-id="event-1"]');
    row.focus();
    press(row, "m");
    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("a view change closes an open preview", () => {
    const { hook } = mountHook();
    const preview = document.createElement("div");
    preview.id = "calendar-preview";
    document.body.appendChild(preview);
    press(document.body, "d");
    expect(pushes(hook, "calendar:close_preview")).toEqual([{ refocus: "false" }]);
  });

  test.each([
    ["a keyboard move", (hook) => (hook.moving = { id: "event-1" })],
    ["a drag", (hook) => (hook.drag = {})],
  ])("are ignored during %s", (_name, start) => {
    const { hook } = mountHook();
    start(hook);
    press(document.body, "d");
    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("are ignored while a modal is open", () => {
    const { hook } = mountHook();
    const modal = document.createElement("div");
    modal.id = "calendar-delete-confirm";
    document.body.appendChild(modal);
    press(document.body, "d");
    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });

  test("are ignored in an editable region", () => {
    const { hook } = mountHook();
    const editable = document.createElement("div");
    editable.setAttribute("contenteditable", "true");
    document.body.appendChild(editable);
    press(editable, "d");
    expect(pushes(hook, "calendar:goto")).toEqual([]);
  });
});

describe("view letters start the next view at the period shown", () => {
  const nextWeek = () => payload({ date: "2026-10-21", range: { from: "2026-10-12", to: "2026-11-01" } });

  test.each([
    ["d", "day"],
    ["x", "three_day"],
    ["a", "agenda"],
  ])("%s from a week without today opens its first day", (key, view) => {
    const { hook } = mountHook(nextWeek());
    press(document.body, key);
    expect(pushes(hook, "calendar:goto")).toEqual([{ view, date: "2026-10-19" }]);
  });

  test("from a week holding today, today, wherever in the week the date sits", () => {
    const { hook } = mountHook(payload({ date: "2026-10-16" }));
    press(document.body, "d");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-14" }]);
  });

  test("from a month without today, its first day, though its grid shows today", () => {
    const { hook } = mountHook(monthPayload({ date: "2026-11-14", range: { from: "2026-09-28", to: "2027-01-11" } }));
    press(document.body, "d");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-11-01" }]);
  });

  test("from a month holding today, today", () => {
    const { hook } = mountHook(monthPayload({ date: "2026-10-27" }));
    press(document.body, "x");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "three_day", date: "2026-10-14" }]);
  });

  test("a step taken before the server answers counts: the pending week is the one shown", () => {
    const { el, hook } = mountHook();
    el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
    press(document.body, "d");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "day", date: "2026-10-19" }]);
  });

  test("from a day, three days or an agenda the date stays", () => {
    const { hook } = mountHook(payload({ view: "day", date: "2026-10-22" }));
    press(document.body, "w");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-22" }]);
  });

  test("on a phone a month keeps the day picked in it", () => {
    mockViewport(true);
    const { hook } = mountHook(monthPayload({ date: "2026-11-14", range: { from: "2026-09-28", to: "2027-01-11" } }));
    press(document.body, "a");
    expect(pushes(hook, "calendar:goto")).toEqual([{ view: "agenda", date: "2026-11-14" }]);
  });
});
