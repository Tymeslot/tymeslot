/**
 * Tests for the CalendarCanvas hook (hooks/calendar_canvas.js): it pulls data
 * on mount, draws from the cache, navigates at once into preloaded periods,
 * and pushes intents back to the LiveComponent.
 */
import { afterEach, expect, test, vi } from "vitest";
import { CalendarCanvas, PENDING_GRACE_MS } from "../../hooks/calendar_canvas.js";
import { addDays } from "../../calendar/time.js";

const strings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  more: "more",
  also_here: "Also here: %{titles}",
  shown_as_free: "shown as free",
  ended: "ended",
  waiting_to_sync: "waiting to sync",
  early_hours: "Before %{time}: %{count}",
  show_early_hours: "Show the hours before %{time}",
  fold_early_hours: "Fold the hours before %{time}",
  open_day: "%{date}, open day view",
  empty_day: "Nothing planned on this day.",
  empty_three_day: "Nothing planned on these days.",
  empty_week: "Nothing planned this week.",
  loading: "Loading calendar",
  list_label: "Events at this time",
};

const settings = { week_start: "monday", show_weekends: true, density: "comfortable", fold_night: true, time_format: "24h", working_hours: {} };
const event = (id, title, start, end) => ({ id, kind: "event", title, all_day: false, start, end, colour: "calendar-2", free: false, attention: false });

function payload(overrides = {}) {
  return {
    view: "week",
    date: "2026-10-14",
    range: { from: "2026-10-05", to: "2026-10-26" },
    now: "2026-10-14T10:30",
    reset: true,
    settings,
    events: [event("event-1", "Design review", "2026-10-14T11:00", "2026-10-14T12:00"), event("event-2", "Planning", "2026-10-21T09:00", "2026-10-21T10:00")],
    ...overrides,
  };
}

const mounted = [];

function mountHook() {
  const el = document.createElement("div");
  el.id = "calendar-canvas";
  el.dataset.view = "week";
  el.dataset.date = "2026-10-14";
  el.dataset.strings = JSON.stringify(strings);
  document.body.appendChild(el);

  const handlers = {};
  const hook = Object.assign(Object.create(CalendarCanvas), {
    el,
    measureWidth: (text) => text.length * 7,
    pushEventTo: vi.fn(),
    handleEvent: (name, callback) => {
      handlers[name] = callback;
    },
  });
  hook.mounted();
  mounted.push(hook);
  return { el, hook, handlers, reply: (data) => hook.pushEventTo.mock.calls[0][3](data) };
}

afterEach(() => {
  vi.useRealTimers();
  while (mounted.length) mounted.pop().destroyed();
  document.body.innerHTML = "";
});

test("asks for data on mount and draws nothing until it arrives", () => {
  const { el, hook } = mountHook();
  const [target, name, params] = hook.pushEventTo.mock.calls[0];
  expect([target, name, params]).toEqual([el, "calendar:ready", { phone: false, tab: expect.any(String) }]);
  expect(el.querySelector(".cal-ev")).toBeNull();
});

test("draws the reply", () => {
  const { el, reply } = mountHook();
  reply(payload());
  expect(el.querySelector('[data-event-id="event-1"]').textContent).toContain("Design review");
  expect(el.getAttribute("aria-busy")).toBe("false");
});

test("navigating into a preloaded week draws it at once", () => {
  const { el, reply } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
  expect(el.querySelector('[data-event-id="event-2"]')).not.toBeNull();
  expect(el.querySelector('[data-event-id="event-1"]')).toBeNull();
});

test("navigating beyond what is loaded shows the skeleton until the server answers", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-11-04" } }));
  expect(el.querySelector(".cal-skeleton")).not.toBeNull();
  expect(el.getAttribute("aria-busy")).toBe("true");

  handlers["calendar:events"](payload({ date: "2026-11-04", range: { from: "2026-10-26", to: "2026-11-16" }, reset: false, events: [] }));
  expect(el.querySelector(".cal-skeleton")).toBeNull();
  expect(el.querySelector(".cal-empty")).not.toBeNull();
});

test("clicking an event asks the server for its preview", () => {
  const { el, hook, reply } = mountHook();
  reply(payload());
  el.querySelector('[data-event-id="event-1"]').click();
  const [, name, params] = hook.pushEventTo.mock.calls.at(-1);
  expect([name, params]).toEqual(["calendar:open", { id: "event-1" }]);
});

test("clicking an event does not reach LiveView's click-away", () => {
  const { el, reply } = mountHook();
  reply(payload());
  const reached = vi.fn();
  document.body.addEventListener("click", reached);
  el.querySelector('[data-event-id="event-1"]').click();
  document.body.removeEventListener("click", reached);
  expect(reached).not.toHaveBeenCalled();
});

test("Enter on a focused event opens it too", () => {
  const { el, hook, reply } = mountHook();
  reply(payload());
  el.querySelector('[data-event-id="event-1"]').dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
  expect(hook.pushEventTo.mock.calls.at(-1)[1]).toBe("calendar:open");
});

test("a day header opens that day here and tells the server", () => {
  const { el, hook, reply } = mountHook();
  reply(payload());
  el.querySelector('[data-goto-day="2026-10-15"]').click();
  expect(hook.pushEventTo.mock.calls.at(-1).slice(1, 3)).toEqual(["calendar:goto", { view: "day", date: "2026-10-15" }]);
  expect(el.querySelectorAll(".cal-col")).toHaveLength(1);
});

test("a +N chip opens a list of its cluster", () => {
  const { el, reply } = mountHook();
  const five = ["a", "b", "c", "d", "e"].map((id) => event(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
  reply(payload({ events: five }));
  el.querySelector(".cal-more").click();
  expect(el.querySelectorAll(".cal-list .cal-list-item")).toHaveLength(5);
});

test("settings pushed by the server redraw the grid", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  handlers["calendar:settings"]({ ...settings, density: "compact" });
  expect(el.querySelector(".cal-grid").getAttribute("style")).toContain("--cal-hour:38px");
});

test("the preview closing hands focus back to the event", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.querySelector('[data-event-id="event-1"]').click();
  handlers["calendar:preview-closed"]();
  expect(document.activeElement.dataset.eventId).toBe("event-1");
});

test("a preview the server opened itself is placed by its event and focused", () => {
  const { reply, handlers } = mountHook();
  reply(payload());
  const preview = document.createElement("div");
  preview.id = "calendar-preview";
  preview.tabIndex = -1;
  document.body.appendChild(preview);

  handlers["calendar:preview-opened"]({ id: "event-1" });

  expect(document.activeElement).toBe(preview);
  expect(document.documentElement.style.getPropertyValue("--cal-pop-x")).toMatch(/^-?\d+px$/);

  // Closing it hands focus back to that event.
  preview.remove();
  handlers["calendar:preview-closed"]();
  expect(document.activeElement.dataset.eventId).toBe("event-1");
});

test("the side panel closing hands focus back to its event", () => {
  const { reply, handlers } = mountHook();
  reply(payload());
  handlers["calendar:panel"]({ open: false, focus: "event-1" });
  expect(document.activeElement.dataset.eventId).toBe("event-1");
});

test("the side panel opening focuses the element it marks", () => {
  const { reply, handlers } = mountHook();
  reply(payload());
  const panel = document.createElement("aside");
  panel.id = "calendar-panel";
  panel.innerHTML = '<input id="calendar-panel-title" data-panel-focus="true">';
  document.body.appendChild(panel);

  handlers["calendar:panel"]({ open: true });

  expect(document.activeElement.id).toBe("calendar-panel-title");
});

test("the folded night opens on click", () => {
  const { el, reply } = mountHook();
  reply(payload({ events: [event("event-3", "Gym", "2026-10-14T05:00", "2026-10-14T06:00")] }));
  expect(el.querySelector('[data-event-id="event-3"]')).toBeNull();
  el.querySelector(".cal-night").click();
  expect(el.querySelector('[data-event-id="event-3"]')).not.toBeNull();
});

test("the days it draws match the week the server named", () => {
  const { el, reply } = mountHook();
  reply(payload());
  const drawn = [...el.querySelectorAll(".cal-col")].map((col) => col.dataset.day);
  expect(drawn).toEqual(Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k)));
});

const fiveAt = () => ["a", "b", "c", "d", "e"].map((id) => event(`event-${id}`, `Meeting ${id}`, "2026-10-14T13:00", "2026-10-14T14:00"));
const days = (iso) => [...document.querySelectorAll(".cal-col")].map((c) => c.dataset.day).includes(iso);

test("a late payload for an intermediate week does not snap the grid back", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-11-04" } }));
  handlers["calendar:events"](payload({ date: "2026-10-21", range: { from: "2026-10-12", to: "2026-11-02" }, reset: false }));
  expect(el.querySelector(".cal-skeleton")).not.toBeNull();
  expect(el.querySelector(".cal-col")).toBeNull();

  handlers["calendar:events"](payload({ date: "2026-11-04", range: { from: "2026-10-26", to: "2026-11-16" }, reset: false, events: [] }));
  expect(el.querySelector(".cal-skeleton")).toBeNull();
  expect(days("2026-11-04")).toBe(true);
});

test("a payload with nothing pending (browser Back) is followed", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  handlers["calendar:events"](payload({ date: "2026-10-21", range: { from: "2026-10-12", to: "2026-11-02" }, reset: false }));
  expect(days("2026-10-21")).toBe(true);
});

test("the minute tick leaves an open list and its focus alone", () => {
  vi.useFakeTimers();
  try {
    const { el, reply } = mountHook();
    reply(payload({ events: fiveAt() }));
    el.querySelector(".cal-more").click();
    const focused = document.activeElement;
    vi.advanceTimersByTime(60_000);
    expect(el.querySelector(".cal-list")).not.toBeNull();
    expect(document.activeElement).toBe(focused);
  } finally {
    vi.useRealTimers();
  }
});

test("a background payload for the same period leaves an open list; the grid follows once it closes", () => {
  const { el, reply } = mountHook();
  reply(payload({ events: fiveAt() }));
  el.querySelector(".cal-more").click();

  reply(payload({ events: [...fiveAt(), event("event-new", "Brand new", "2026-10-15T09:00", "2026-10-15T10:00")] }));
  expect(el.querySelector(".cal-list")).not.toBeNull();
  expect(el.textContent).not.toContain("Brand new");

  el.querySelector(".cal-list").dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  expect(el.querySelector(".cal-list")).toBeNull();
  expect(el.textContent).toContain("Brand new");
});

test("a resize redraws only when the width changed, batched per frame", () => {
  const frames = [];
  vi.stubGlobal("requestAnimationFrame", (fn) => frames.push(fn) && frames.length);
  vi.stubGlobal("cancelAnimationFrame", () => {});
  try {
    const { el, hook, reply } = mountHook();
    reply(payload());
    const render = vi.spyOn(hook, "render");
    hook.resized();
    expect(frames).toHaveLength(0);
    Object.defineProperty(el, "clientWidth", { value: 700, configurable: true });
    hook.resized();
    expect(render).not.toHaveBeenCalled();
    frames.pop()();
    expect(render).toHaveBeenCalledTimes(1);
  } finally {
    vi.unstubAllGlobals();
  }
});

function shortViewport() {
  vi.stubGlobal("innerWidth", 380);
  vi.stubGlobal("innerHeight", 300);
}

function middleAnchor(node) {
  node.getBoundingClientRect = () => ({ left: 100, right: 140, top: 150, bottom: 170, width: 40, height: 20 });
}

test("a list that fits neither side is capped and scrolls", () => {
  shortViewport();
  try {
    const { el, reply } = mountHook();
    reply(payload({ events: fiveAt() }));
    const chip = el.querySelector(".cal-more");
    chip.getBoundingClientRect = () => ({ left: 100, right: 140, top: 120, bottom: 160, width: 40, height: 40 });
    chip.click();
    expect(el.querySelector(".cal-list").style.maxHeight).toMatch(/^\d+px$/);
  } finally {
    vi.unstubAllGlobals();
  }
});

test("a preview that fits neither side is capped through --cal-pop-h", () => {
  shortViewport();
  try {
    const { el, hook, reply } = mountHook();
    reply(payload());
    const anchor = el.querySelector('[data-event-id="event-1"]');
    middleAnchor(anchor);
    anchor.click();
    expect(document.documentElement.style.getPropertyValue("--cal-pop-h")).toMatch(/^\d+px$/);

    const preview = document.createElement("div");
    preview.id = "calendar-preview";
    preview.tabIndex = -1;
    Object.defineProperty(preview, "offsetHeight", { value: 20 });
    document.body.appendChild(preview);
    hook.pushEventTo.mock.calls.at(-1)[3]();
    expect(document.documentElement.style.getPropertyValue("--cal-pop-h")).toBe("");
  } finally {
    vi.unstubAllGlobals();
  }
});

test("Escape in the list hands focus back to its chip, even after a redraw", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload({ events: fiveAt() }));
  el.querySelector(".cal-more").click();
  handlers["calendar:settings"]({ ...settings, density: "compact" });
  el.querySelector(".cal-more").click();
  expect(el.contains(document.activeElement)).toBe(true);
  document.activeElement.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  expect(el.querySelector(".cal-list")).toBeNull();
  expect(document.activeElement.classList.contains("cal-more")).toBe(true);
});

test("a held key does not repeat Escape or Enter", () => {
  const { el, hook, reply } = mountHook();
  reply(payload());
  const before = hook.pushEventTo.mock.calls.length;
  el.querySelector('[data-event-id="event-1"]').dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", repeat: true, bubbles: true }));
  expect(hook.pushEventTo.mock.calls).toHaveLength(before);
});

test("a pointer press outside the list closes it", () => {
  const { el, reply } = mountHook();
  reply(payload({ events: fiveAt() }));
  el.querySelector(".cal-more").click();
  el.querySelector(".cal-list").dispatchEvent(new Event("pointerdown", { bubbles: true }));
  expect(el.querySelector(".cal-list")).not.toBeNull();
  document.body.dispatchEvent(new Event("pointerdown", { bubbles: true }));
  expect(el.querySelector(".cal-list")).toBeNull();
});

test("pressing the +N chip again closes its list", () => {
  const { el, reply } = mountHook();
  reply(payload({ events: fiveAt() }));
  const chip = el.querySelector(".cal-more");
  chip.click();
  chip.dispatchEvent(new Event("pointerdown", { bubbles: true }));
  expect(el.querySelector(".cal-list")).not.toBeNull();
  chip.click();
  expect(el.querySelector(".cal-list")).toBeNull();
});

test("a minute tick skipped while the list is open redraws once it closes", () => {
  vi.useFakeTimers();
  try {
    const { el, hook, reply } = mountHook();
    reply(payload({ events: fiveAt() }));
    el.querySelector(".cal-more").click();
    const render = vi.spyOn(hook, "render");
    vi.advanceTimersByTime(60_000);
    expect(render).not.toHaveBeenCalled();
    document.body.dispatchEvent(new Event("pointerdown", { bubbles: true }));
    expect(render).toHaveBeenCalledTimes(1);
  } finally {
    vi.useRealTimers();
  }
});

test("the scroll position survives a visit to the skeleton", () => {
  const { el, hook, reply, handlers } = mountHook();
  reply(payload());
  el.querySelector("[data-scroll]").scrollTop = 123;
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-11-04" } }));
  expect(hook.scrollTop).toBe(123);
  handlers["calendar:events"](payload({ date: "2026-11-04", range: { from: "2026-10-26", to: "2026-11-16" }, reset: false, events: [] }));
  expect(el.querySelector("[data-scroll]").scrollTop).toBe(123);
});

test("destroyed removes the popover variables and the document listener", () => {
  const { el, hook, reply } = mountHook();
  // Wide enough for a visible event beside the chip.
  Object.defineProperty(el, "clientWidth", { value: 700, configurable: true });
  reply(payload({ events: fiveAt() }));
  el.querySelector('[data-event-id="event-a"]').click();
  el.querySelector(".cal-more").click();
  const remove = vi.spyOn(document, "removeEventListener");
  hook.destroyed();
  expect(remove).toHaveBeenCalledWith("pointerdown", hook.outside);
  for (const name of ["--cal-pop-x", "--cal-pop-y", "--cal-pop-h"]) expect(document.documentElement.style.getPropertyValue(name)).toBe("");
});

test("reconnecting asks the server for the data again", () => {
  const { hook, reply } = mountHook();
  reply(payload());
  hook.reconnected();
  expect(hook.pushEventTo.mock.calls).toHaveLength(2);
  expect(hook.pushEventTo.mock.calls[1][1]).toBe("calendar:ready");
  // The new server process hears the same tab again.
  expect(hook.pushEventTo.mock.calls[1][2].tab).toBe(hook.pushEventTo.mock.calls[0][2].tab);
});

test("a navigation to the days already shown holds nothing pending, so Back is still followed", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-16" } }));
  expect(days("2026-10-14")).toBe(true);
  handlers["calendar:events"](payload({ date: "2026-10-21", range: { from: "2026-10-12", to: "2026-11-02" }, reset: false }));
  expect(days("2026-10-21")).toBe(true);
});

test("the server's period answer settles a pending navigation that needed no new events", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
  handlers["calendar:period"]({ view: "week", date: "2026-10-21" });
  // Browser Back: nothing is pending any more, so the server leads.
  handlers["calendar:period"]({ view: "week", date: "2026-10-14" });
  expect(days("2026-10-14")).toBe(true);
  expect(days("2026-10-21")).toBe(false);
});

test("a period answer for an intermediate target leaves the pending one alone", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
  handlers["calendar:period"]({ view: "week", date: "2026-10-14" });
  expect(days("2026-10-21")).toBe(true);
});

test("two steps before the server answers advance two periods and tell the server", () => {
  const { el, hook, reply, handlers } = mountHook();
  reply(payload());
  const next = () => el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21", step: 1 } }));
  next();
  expect(hook.pushEventTo.mock.calls.map((call) => call[1])).not.toContain("calendar:goto");
  next();
  expect(hook.pushEventTo.mock.calls.at(-1).slice(1, 3)).toEqual(["calendar:goto", { view: "week", date: "2026-10-28" }]);

  // The first click's payload must not pull the grid back a week.
  handlers["calendar:events"](payload({ date: "2026-10-21", range: { from: "2026-10-12", to: "2026-11-02" }, reset: false }));
  expect(days("2026-10-28")).toBe(true);
});

test("closing a preview opened from a +N list hands focus back to its chip", () => {
  const { el, reply, handlers } = mountHook();
  reply(payload({ events: fiveAt() }));
  el.querySelector(".cal-more").click();
  const item = el.querySelector('.cal-list [data-event-id="event-e"]');
  item.focus();
  item.click();
  document.body.focus();
  handlers["calendar:preview-closed"]();
  expect(document.activeElement.classList.contains("cal-more")).toBe(true);
});

test("the minute tick keeps focus on a day header", () => {
  vi.useFakeTimers();
  try {
    const { el, reply } = mountHook();
    reply(payload());
    el.querySelector('[data-goto-day="2026-10-15"]').focus();
    vi.advanceTimersByTime(60_000);
    expect(document.activeElement.dataset.gotoDay).toBe("2026-10-15");
    expect(el.contains(document.activeElement)).toBe(true);
  } finally {
    vi.useRealTimers();
  }
});

test("the minute tick keeps focus on a column's early-hours button, not the axis one", () => {
  vi.useFakeTimers();
  try {
    const { el, reply } = mountHook();
    reply(payload({ events: [event("event-3", "Gym", "2026-10-15T05:00", "2026-10-15T06:00")] }));
    el.querySelector('.cal-col[data-day="2026-10-15"] .cal-early').focus();
    vi.advanceTimersByTime(60_000);
    expect(document.activeElement.closest(".cal-col")?.dataset.day).toBe("2026-10-15");
  } finally {
    vi.useRealTimers();
  }
});

test("a reconnect drops the pending target and follows the server's answer", () => {
  const { el, hook, reply } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-11-04" } }));
  expect(el.querySelector(".cal-skeleton")).not.toBeNull();

  hook.reconnected();
  // The server read the URL it had, which still names the week before.
  hook.pushEventTo.mock.calls.at(-1)[3](payload());
  expect(el.querySelector(".cal-skeleton")).toBeNull();
  expect(days("2026-10-14")).toBe(true);
});

test("an answer for another period takes over once the grace runs out", () => {
  vi.useFakeTimers();
  const { el, reply, handlers } = mountHook();
  reply(payload());
  // A date the server cannot show (far future): it falls back to this week.
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "9999-12-29" } }));
  handlers["calendar:events"](payload({ reset: false }));
  expect(el.querySelector(".cal-skeleton")).not.toBeNull();

  vi.advanceTimersByTime(PENDING_GRACE_MS);
  expect(el.querySelector(".cal-skeleton")).toBeNull();
  expect(days("2026-10-14")).toBe(true);
});

test("the answer asked for, arriving within the grace, still wins over an intermediate one", () => {
  vi.useFakeTimers();
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-11-04" } }));
  handlers["calendar:events"](payload({ date: "2026-10-21", range: { from: "2026-10-12", to: "2026-11-02" }, reset: false }));
  vi.advanceTimersByTime(PENDING_GRACE_MS / 2);
  handlers["calendar:events"](payload({ date: "2026-11-04", range: { from: "2026-10-26", to: "2026-11-16" }, reset: false, events: [] }));
  vi.advanceTimersByTime(PENDING_GRACE_MS);
  expect(days("2026-11-04")).toBe(true);
});

test("a period answer for another week also takes over after the grace", () => {
  vi.useFakeTimers();
  const { el, reply, handlers } = mountHook();
  reply(payload());
  el.dispatchEvent(new CustomEvent("calendar:navigate", { detail: { view: "week", date: "2026-10-21" } }));
  handlers["calendar:period"]({ view: "week", date: "2026-10-14" });
  expect(days("2026-10-21")).toBe(true);
  vi.advanceTimersByTime(PENDING_GRACE_MS);
  expect(days("2026-10-14")).toBe(true);
});
