/**
 * Tests for drafting in the CalendarCanvas hook (hooks/calendar_canvas/draft.js):
 * a click or a drag on an empty slot drops a draft, a press with something
 * open only closes it, existing drags and "+N" lists keep working, and the
 * server's own drafts are drawn in step with the local one.
 */
import { afterEach, expect, test, vi } from "vitest";
import { addDays, makeScale } from "../../calendar/time.js";
import { block, event, mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const column = (el, iso) => el.querySelector(`.cal-col[data-day="${iso}"]`);
const drafts = (el) => [...el.querySelectorAll("[data-draft-id]")];

// Columns 100px wide from x = 0; the day starts at y = 0 with 52px an hour.
function withGeometry(hook) {
  hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  return hook;
}

function pointer(type, target, x, y, extra = {}) {
  const e = new MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0 });
  Object.defineProperty(e, "pointerId", { value: extra.pointerId ?? 1 });
  Object.defineProperty(e, "buttons", { value: extra.buttons ?? (type === "pointerup" ? 0 : 1) });
  if (extra.pointerType) Object.defineProperty(e, "pointerType", { value: extra.pointerType });
  return target.dispatchEvent(e);
}

const click = (target, x, y) => target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: x, clientY: y }));

// A press and release in place, then the click the browser sends after it.
function tap(target, x, y, extra = {}) {
  pointer("pointerdown", target, x, y, extra);
  pointer("pointerup", target, x, y, extra);
  click(target, x, y);
}

afterEach(() => {
  unmountAll();
  vi.unstubAllGlobals();
});

test("a click on an empty slot drops a 30-minute draft on the quarter hour under it", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  // Thursday, 9:11.
  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);

  const [draft] = drafts(el);
  expect(draft.closest("[data-day]").dataset.day).toBe("2026-10-15");
  expect(draft.querySelector(".cal-ev-title").textContent).toBe("New event");
  // One row tall: the start only, as an event block of that height shows.
  expect(draft.querySelector(".cal-ev-time").textContent).toBe("09:00");
  expect(draft.getAttribute("aria-hidden")).toBe("true");
  expect(draft.style.getPropertyValue("--cal-ev")).toBe("var(--color-calendar-3)");
  expect(hook.draft).toMatchObject({ calendar: "7:work", status: "editing" });
  expect(hook.pushEventTo).not.toHaveBeenCalled();
});

test("the draft is not an event: it takes no focus and opens no preview", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);

  const draft = drafts(el)[0];
  expect(draft.hasAttribute("data-event-id")).toBe(false);
  expect(draft.hasAttribute("tabindex")).toBe(false);
  click(draft, 350, 52 * 9 + 10);
  expect(pushes(hook, "calendar:open")).toEqual([]);
});

test("dragging on an empty slot draws the span and drops a draft over it", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  const thursday = column(el, "2026-10-15");

  pointer("pointerdown", thursday, 350, 52 * 9);
  pointer("pointermove", el, 350, 52 * 9 + 12);
  pointer("pointermove", el, 350, 555);

  const drawing = el.querySelector(".cal-ev.is-drawing");
  expect(drawing.querySelector(".cal-ev-time").textContent).toBe("09:00–10:45");
  expect(hook.draft).toBeNull();

  pointer("pointerup", el, 350, 555);
  click(el, 350, 555);

  expect(el.querySelector(".is-drawing")).toBeNull();
  expect(drafts(el)).toHaveLength(1);
  expect(drafts(el)[0].querySelector(".cal-ev-time").textContent).toBe("09:00–10:45");
});

test("dragging upwards covers the same span", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", column(el, "2026-10-15"), 350, 555);
  pointer("pointermove", el, 350, 520);
  pointer("pointermove", el, 350, 52 * 9);
  pointer("pointerup", el, 350, 52 * 9);

  expect(drafts(el)[0].querySelector(".cal-ev-time").textContent).toBe("09:00–10:45");
});

test("Escape while drawing a span cancels it and its release drops nothing", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", column(el, "2026-10-15"), 350, 52 * 9);
  pointer("pointermove", el, 350, 555);
  document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  pointer("pointerup", el, 350, 555);
  click(el, 350, 555);

  expect(el.querySelector(".is-drawing")).toBeNull();
  expect(hook.draft).toBeNull();
});

test("touch does not draw a span, but a tap still drops a draft", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  const thursday = column(el, "2026-10-15");

  pointer("pointerdown", thursday, 350, 52 * 9, { pointerType: "touch" });
  pointer("pointermove", el, 350, 555, { pointerType: "touch" });
  expect(el.querySelector(".is-drawing")).toBeNull();
  pointer("pointerup", el, 350, 555, { pointerType: "touch" });

  tap(thursday, 350, 52 * 9 + 10, { pointerType: "touch" });
  expect(drafts(el)).toHaveLength(1);
});

test("a press with a draft open only closes it", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);

  tap(column(el, "2026-10-16"), 450, 52 * 15);

  expect(drafts(el)).toHaveLength(0);
  expect(hook.draft).toBeNull();
});

test("a press with the event preview open only lets it close", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  const preview = document.createElement("div");
  preview.id = "calendar-preview";
  document.body.appendChild(preview);

  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);

  expect(hook.draft).toBeNull();
});

test("a press on an editable event still drags it and drops no draft", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", block(el, "event-1"), 250, 582);
  pointer("pointermove", el, 260, 592);
  pointer("pointermove", el, 350, 634);
  pointer("pointerup", el, 350, 634);
  click(el, 350, 634);

  expect(pushes(hook, "calendar:move")).toEqual([{ id: "event-1", start: "2026-10-15T12:00", end: "2026-10-15T13:00" }]);
  expect(hook.draft).toBeNull();
});

test("a \"+N\" chip still opens its list, and the next press on a slot only closes it", () => {
  const crowd = ["a", "b", "c", "d", "e"].map((k) => event(`event-${k}`, `Talk ${k}`, "2026-10-15T09:00", "2026-10-15T10:00"));
  const { el, hook } = mountHook(payload({ events: crowd }));
  withGeometry(hook);

  el.querySelector(".cal-more").click();
  expect(el.querySelector(".cal-list")).not.toBeNull();

  tap(column(el, "2026-10-14"), 250, 52 * 15);
  expect(el.querySelector(".cal-list")).toBeNull();
  expect(hook.draft).toBeNull();
});

test("a click in a folded night drops nothing", () => {
  const { el, hook } = mountHook(payload({ settings: { ...payload().settings, fold_night: true } }));
  hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, true) });

  click(column(el, "2026-10-15"), 350, 10);

  expect(hook.draft).toBeNull();
});

test("the server's pending draft is drawn with Saving… and our own copy wins while it is open", () => {
  const serverDraft = event("draft-d9", "Lunch", "2026-10-16T12:00", "2026-10-16T13:00", { kind: "draft", pending: true, editable: false, movable: false });
  const { el, hook, handlers } = mountHook(payload({ events: [...payload().events, serverDraft] }));
  withGeometry(hook);

  const drawn = el.querySelector('[data-draft-id="draft-d9"]');
  expect(drawn.classList.contains("is-pending")).toBe(true);
  expect(drawn.querySelector(".cal-ev-saving").textContent).toBe("Saving…");

  tap(column(el, "2026-10-16"), 450, 52 * 12 + 5);
  hook.draft = { ...hook.draft, id: "d9", title: "Mine" };
  hook.render();
  const both = el.querySelectorAll('[data-draft-id="draft-d9"]');
  expect(both).toHaveLength(1);
  expect(both[0].querySelector(".cal-ev-title").textContent).toBe("Mine");
  expect(both[0].classList.contains("is-pending")).toBe(false);
  hook.draft = null;
  hook.render();
  handlers["calendar:events"](payload({ reset: false }));
  expect(el.querySelector('[data-draft-id="draft-d9"]')).toBeNull();
});

test("a handed-over draft is drawn until the server's next payload", () => {
  const { el, hook, handlers } = mountHook();
  withGeometry(hook);
  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);
  const id = hook.draft.id;

  hook.handOver("created");
  const saving = el.querySelector(`[data-draft-id="draft-${id}"]`);
  expect(saving.querySelector(".cal-ev-saving").textContent).toBe("Saving…");

  const serverCopy = event(`draft-${id}`, "", "2026-10-15T09:00", "2026-10-15T09:30", { kind: "draft", pending: true, editable: false, movable: false });
  handlers["calendar:events"](payload({ reset: false, events: [...payload().events, serverCopy] }));
  expect(hook.handed.size).toBe(0);
  expect(el.querySelectorAll(`[data-draft-id="draft-${id}"]`)).toHaveLength(1);
});

test("calendar:draft-cleared drops a handed-over draft at once", () => {
  const { el, hook, handlers } = mountHook();
  withGeometry(hook);
  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);
  const id = hook.draft.id;
  hook.handOver("created");

  handlers["calendar:draft-cleared"]({ draft: id });

  expect(drafts(el)).toHaveLength(0);
});

test("an all-day draft takes the first lane of the all-day row", () => {
  const holiday = event("event-h", "Holiday", "2026-10-15", "2026-10-16", { all_day: true });
  const { el, hook } = mountHook(payload({ events: [holiday] }));
  withGeometry(hook);
  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);

  hook.draft = { ...hook.draft, allDay: true, start: hook.draft.start - (hook.draft.start % 1440), end: hook.draft.start - (hook.draft.start % 1440) + 1440 };
  hook.render();

  const bar = el.querySelector('.cal-adbar[data-draft-id]');
  expect(bar.textContent).toBe("New event");
  expect(bar.style.gridRow).toMatch(/^1/);
});

test("a typed title is escaped where the draft is drawn", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);
  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);

  hook.draft = { ...hook.draft, title: '<img src=x onerror="alert(1)">' };
  hook.render();

  expect(el.querySelector("[data-draft-id] img")).toBeNull();
  expect(drafts(el)[0].querySelector(".cal-ev-title").textContent).toBe('<img src=x onerror="alert(1)">');
});

test("a press that never saw its release cannot start a create drag later", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", column(el, "2026-10-15"), 350, 52 * 9);
  // The release was lost; a later press on a layer-free button must not inherit it.
  pointer("pointerdown", el.querySelector("button") ?? el, 350, 52 * 9, { pointerId: 2 });
  pointer("pointermove", el, 350, 555, { pointerId: 1 });

  expect(el.querySelector(".is-drawing")).toBeNull();
});

test("a context menu while drawing a span cancels it", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", column(el, "2026-10-15"), 350, 52 * 9);
  pointer("pointermove", el, 350, 555);
  expect(el.querySelector(".is-drawing")).not.toBeNull();
  el.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));

  expect(el.querySelector(".is-drawing")).toBeNull();
  expect(hook.createDrag).toBeNull();
});

test("a server all-day draft is not listed as an event in the all-day \"+N\" list", () => {
  const holidays = ["a", "b", "c", "d"].map((k) => event(`event-${k}`, `Holiday ${k}`, "2026-10-15", "2026-10-16", { all_day: true }));
  const serverDraft = event("draft-s1", "Server draft", "2026-10-15", "2026-10-16", { all_day: true, kind: "draft", pending: true, editable: false, movable: false });
  const { el, hook } = mountHook(payload({ events: [...holidays, serverDraft] }));
  withGeometry(hook);

  el.querySelector("[data-allday-more]").click();

  const list = el.querySelector(".cal-list");
  expect(list).not.toBeNull();
  expect(list.textContent).not.toContain("Server draft");
});

test("a payload arriving while a local draft is open keeps that draft", () => {
  const { el, hook, handlers } = mountHook();
  withGeometry(hook);
  tap(column(el, "2026-10-15"), 350, 52 * 9 + 10);
  const id = hook.draft.id;

  handlers["calendar:events"](payload({ reset: false }));

  expect(hook.draft?.id).toBe(id);
  expect(el.querySelectorAll(`[data-draft-id="draft-${id}"]`)).toHaveLength(1);
});

test("destroying the hook mid-draw removes the drawing block and later input does not throw", () => {
  const { el, hook } = mountHook();
  withGeometry(hook);

  pointer("pointerdown", column(el, "2026-10-15"), 350, 52 * 9);
  pointer("pointermove", el, 350, 555);
  expect(el.querySelector(".is-drawing")).not.toBeNull();
  hook.destroyed();

  expect(el.querySelector(".is-drawing")).toBeNull();
  expect(() => {
    document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
    pointer("pointermove", el, 350, 600);
  }).not.toThrow();
});
