/**
 * Tests for the quick-create popover in the CalendarCanvas hook
 * (hooks/calendar_canvas/create.js): it opens on a new draft, typing and
 * the chips move the draft, Save and More options push to the server and
 * follow its reply, and Escape, a press outside and Tab behave.
 */
import { afterEach, expect, test, vi } from "vitest";
import { addDays, makeScale } from "../../calendar/time.js";
import { mountHook, payload, pushes, unmountAll } from "./canvas_harness.js";

const days = Array.from({ length: 7 }, (_, k) => addDays("2026-10-12", k));
const popover = () => document.getElementById("calendar-quick-create");
const field = () => document.getElementById("calendar-qc-field");
const drawn = (el) => el.querySelector("[data-draft-id]");

function open({ first } = {}) {
  const mounted = mountHook(first);
  mounted.hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  // Thursday 15 October, 09:00.
  const column = mounted.el.querySelector('.cal-col[data-day="2026-10-15"]');
  column.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: 350, clientY: 52 * 9 + 10 }));
  return mounted;
}

function type(text) {
  field().value = text;
  field().dispatchEvent(new Event("input", { bubbles: true }));
}

const key = (target, k, extra = {}) => target.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...extra }));
const reply = (hook, name, answer) => hook.pushEventTo.mock.calls.find(([, pushed]) => pushed === name)[3](answer);

afterEach(() => {
  unmountAll();
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

test("a new draft opens the popover with the field focused", () => {
  open();
  expect(popover().getAttribute("role")).toBe("dialog");
  expect(document.activeElement).toBe(field());
  expect(popover().querySelector('[data-qc-pick="start"]').textContent).toBe("09:00");
});

test("typing moves the draft and names it at once", () => {
  const { el } = open();
  type("Design sync 14:00-15:30");

  expect(drawn(el).querySelector(".cal-ev-title").textContent).toBe("Design sync");
  expect(drawn(el).querySelector(".cal-ev-time").textContent).toBe("14:00–15:30");
  expect(popover().querySelector('[data-qc-pick="end"]').textContent).toBe("15:30");
  expect(document.activeElement).toBe(field());
});

test("Enter saves: the draft's fields go to the server and the popover waits for the reply", () => {
  const { el, hook } = open();
  type("Lunch 12:30 ;Café Nero");
  key(field(), "Enter");

  expect(pushes(hook, "calendar:create")).toEqual([
    {
      draft: hook.draft.id,
      title: "Lunch",
      start: "2026-10-15T12:30",
      end: "2026-10-15T13:00",
      all_day: false,
      calendar: "7:work",
      location: "Café Nero",
      guests: [],
      free: false,
    },
  ]);
  expect(popover().querySelector("[data-qc-save]").textContent).toBe("Saving…");
  expect(drawn(el).querySelector(".cal-ev-saving").textContent).toBe("Saving…");
  // A second Enter does not send it twice.
  key(field(), "Enter");
  expect(pushes(hook, "calendar:create")).toHaveLength(1);
});

test("accepted, the popover closes and the draft stays drawn as saving", () => {
  const { el, hook } = open();
  type("Lunch");
  popover().querySelector("[data-qc-save]").click();
  reply(hook, "calendar:create", { accepted: true });

  expect(popover()).toBeNull();
  expect(hook.draft).toBeNull();
  expect(drawn(el).querySelector(".cal-ev-saving")).not.toBeNull();
});

test("refused, the message shows on the chip it names and the popover stays open", () => {
  const { hook } = open();
  type("Lunch");
  key(field(), "Enter");
  reply(hook, "calendar:create", { accepted: false, field: "start", error: "That time doesn't exist here." });

  expect(popover().querySelector("#calendar-qc-error").textContent).toBe("That time doesn't exist here.");
  expect(popover().querySelector('[data-qc-pick="start"]').getAttribute("aria-invalid")).toBe("true");
  expect(popover().querySelector("[data-qc-save]").disabled).toBe(false);
  expect(document.activeElement).toBe(field());
  expect(field().value).toBe("Lunch");
});

test("refused without a field (rate limited), the message stands on its own", () => {
  const { hook } = open();
  key(field(), "Enter");
  reply(hook, "calendar:create", { accepted: false, field: null, error: "Too many new events at once. Try again in a minute." });

  expect(popover().querySelector("#calendar-qc-error").textContent).toBe("Too many new events at once. Try again in a minute.");
  expect(popover().querySelectorAll('[aria-invalid="true"]')).toHaveLength(0);
});

test("a reply with no message falls back to the generic refusal", () => {
  const { hook } = open();
  key(field(), "Enter");
  reply(hook, "calendar:create", undefined);
  expect(popover().querySelector("#calendar-qc-error").textContent).toBe("Couldn't save this event. Try again.");
});

test("guests turn Save into Save and invite", () => {
  open();
  type("1:1 @anna@example.com");
  expect(popover().querySelector("[data-qc-save]").textContent).toBe("Save and invite");
});

test("the time chips' inputs move the draft, the end following the start", () => {
  const { el } = open();
  const input = popover().querySelector('[data-qc-input="start"]');
  input.value = "11:00";
  input.dispatchEvent(new Event("change", { bubbles: true }));

  // A 30-minute draft is one row: it shows its start, as an event does.
  expect(drawn(el).querySelector(".cal-ev-time").textContent).toBe("11:00");
  expect(popover().querySelector('[data-qc-input="end"]').value).toBe("11:30");
});

test("a chip opens the native picker, or shows the input where there is none", () => {
  open();
  const showPicker = vi.fn();
  const date = popover().querySelector('[data-qc-input="date"]');
  date.showPicker = showPicker;
  popover().querySelector('[data-qc-pick="date"]').click();
  expect(showPicker).toHaveBeenCalled();

  const start = popover().querySelector('[data-qc-input="start"]');
  start.showPicker = () => {
    throw new Error("NotAllowedError");
  };
  popover().querySelector('[data-qc-pick="start"]').click();
  expect(start.classList.contains("is-open")).toBe(true);
  expect(start.hasAttribute("aria-hidden")).toBe(false);
  expect(document.activeElement).toBe(start);
});

test("the calendar select and Busy/Free change the draft and keep focus where it was", () => {
  const { el, hook } = open();
  const select = popover().querySelector('[data-qc-input="calendar"]');
  select.value = "7:personal";
  select.dispatchEvent(new Event("change", { bubbles: true }));
  expect(drawn(el).style.getPropertyValue("--cal-ev")).toBe("var(--color-calendar-5)");

  const free = popover().querySelector('[data-qc-free="true"]');
  free.focus();
  free.click();
  expect(hook.draft.free).toBe(true);
  expect(document.activeElement).toBe(popover().querySelector('[data-qc-free="true"]'));
  expect(document.activeElement.getAttribute("aria-pressed")).toBe("true");
});

test("all day switches the draft to the all-day row", () => {
  const { el } = open();
  popover().querySelector("[data-qc-allday]").click();
  expect(el.querySelector(".cal-adbar[data-draft-id]")).not.toBeNull();
  expect(popover().querySelector('[data-qc-pick="start"]')).toBeNull();
});

test("More options hands the draft to the panel once it opened", () => {
  const { el, hook } = open();
  type("Planning");
  popover().querySelector("[data-qc-more]").click();

  expect(pushes(hook, "calendar:more_options")[0]).toMatchObject({ title: "Planning", start: "2026-10-15T09:00" });
  expect(popover()).not.toBeNull();
  reply(hook, "calendar:more_options", { opened: true });

  expect(popover()).toBeNull();
  expect(drawn(el)).not.toBeNull();
  expect(drawn(el).querySelector(".cal-ev-saving")).toBeNull();
});

test("Escape cancels, drops the draft and returns focus", () => {
  const button = document.createElement("button");
  document.body.appendChild(button);
  button.focus();
  const { el, hook } = mountHook();
  hook.gridGeometry = () => ({ left: 0, top: 0, colWidth: 100, days, scale: makeScale(52, false) });
  el.querySelector('.cal-col[data-day="2026-10-15"]').dispatchEvent(new MouseEvent("click", { bubbles: true, clientX: 350, clientY: 500 }));

  const escape = new KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true });
  const windowSaw = vi.fn();
  window.addEventListener("keydown", windowSaw);
  field().dispatchEvent(escape);
  window.removeEventListener("keydown", windowSaw);

  expect(popover()).toBeNull();
  expect(drawn(el)).toBeNull();
  expect(document.activeElement).toBe(button);
  expect(windowSaw).not.toHaveBeenCalled();
});

test("a press outside cancels; a press on the draft does not", () => {
  const { el } = open();
  drawn(el).dispatchEvent(new MouseEvent("pointerdown", { bubbles: true }));
  expect(popover()).not.toBeNull();

  document.body.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true }));
  expect(popover()).toBeNull();
  expect(drawn(el)).toBeNull();
});

test("a draft being saved is not cancelled by Escape or a press outside", () => {
  const { el } = open();
  key(field(), "Enter");
  key(field(), "Escape");
  document.body.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true }));
  expect(popover()).not.toBeNull();
  expect(drawn(el)).not.toBeNull();
});

test("Tab cycles inside the popover", () => {
  open();
  const save = popover().querySelector("[data-qc-save]");
  save.focus();
  key(save, "Tab");
  expect(document.activeElement).toBe(field());
  key(field(), "Tab", { shiftKey: true });
  expect(document.activeElement).toBe(save);
});

test("keys typed in the field never reach the page's shortcuts", () => {
  const { hook } = open();
  const pageSaw = vi.fn();
  document.addEventListener("keydown", pageSaw);
  key(field(), "z", { ctrlKey: true });
  document.removeEventListener("keydown", pageSaw);
  expect(pageSaw).not.toHaveBeenCalled();
  expect(pushes(hook, "calendar:undo")).toEqual([]);
});

test("a typed day outside the visible week moves the grid there after a pause", () => {
  vi.useFakeTimers();
  const { hook } = open();
  type("Review 27/10");
  expect(pushes(hook, "calendar:goto")).toEqual([]);

  vi.advanceTimersByTime(400);
  expect(pushes(hook, "calendar:goto")).toEqual([{ view: "week", date: "2026-10-27" }]);
  expect(popover()).not.toBeNull();
});

test("the popover is placed beside the draft, never over it", () => {
  const { el, hook } = open();
  vi.stubGlobal("innerWidth", 1280);
  vi.stubGlobal("innerHeight", 800);
  drawn(el).getBoundingClientRect = () => ({ left: 300, right: 400, top: 468, bottom: 494, width: 100, height: 26 });
  hook.placeQuickCreate();
  expect([popover().style.left, popover().style.top]).toEqual(["408px", "468px"]);

  // No room on the right: it goes to the left of the draft.
  drawn(el).getBoundingClientRect = () => ({ left: 1000, right: 1100, top: 468, bottom: 494, width: 100, height: 26 });
  hook.placeQuickCreate();
  expect(popover().style.left).toBe(`${1000 - 8 - 340}px`);
});

test("calendar:draft-cleared after a failed create removes the saving draft", () => {
  const { el, hook, handlers } = open();
  key(field(), "Enter");
  const { id } = hook.draft;
  reply(hook, "calendar:create", { accepted: true });

  handlers["calendar:draft-cleared"]({ draft: id });
  expect(drawn(el)).toBeNull();
});

test("the popover does not outlive the hook", () => {
  open();
  unmountAll();
  expect(popover()).toBeNull();
});

const refusal = "Couldn't save this event. Try again.";

const unconfirmed = "Couldn't confirm the save. Check your calendar.";
const notice = () => document.getElementById("calendar-notice");

// A lost reply may hide a create that landed, so Save is never offered again.
function expectDropped(el, hook) {
  expect(popover()).toBeNull();
  expect(hook.draft).toBeNull();
  expect(drawn(el)).toBeNull();
  expect(notice().getAttribute("role")).toBe("alert");
  expect(notice().textContent).toBe(unconfirmed);
  expect(pushes(hook, "calendar:create")).toHaveLength(1);
}

test("a rejected create push drops the draft and asks the organiser to check", async () => {
  const { el, hook } = open();
  hook.pushEventTo.mockImplementation(() => Promise.reject(new Error("disconnected")));
  type("Lunch");
  key(field(), "Enter");
  await Promise.resolve();
  await Promise.resolve();

  expectDropped(el, hook);
});

test("a create with no reply in time drops the draft and asks the organiser to check", () => {
  vi.useFakeTimers();
  const { el, hook } = open();
  type("Lunch");
  key(field(), "Enter");
  expect(hook.draft.status).toBe("saving");

  vi.advanceTimersByTime(15000);
  expectDropped(el, hook);
  // A late reply changes nothing.
  reply(hook, "calendar:create", { accepted: true });
  expect(popover()).toBeNull();

  // The notice leaves on its own, like the server's toast.
  vi.advanceTimersByTime(10000);
  expect(notice()).toBeNull();
});

test("reconnecting while a draft is saving drops it and asks the organiser to check", () => {
  const { el, hook } = open();
  type("Lunch");
  key(field(), "Enter");
  hook.reconnected();

  expectDropped(el, hook);
  expect(document.activeElement).not.toBe(document.body);

  notice().querySelector("button").click();
  expect(notice()).toBeNull();
});

test("the notice goes once the server settles that draft after all", () => {
  vi.useFakeTimers();
  const { hook, handlers } = open();
  type("Lunch");
  key(field(), "Enter");
  const [{ draft }] = pushes(hook, "calendar:create");
  vi.advanceTimersByTime(15000);
  expect(notice()).not.toBeNull();

  // Another draft's answer leaves it.
  handlers["calendar:create-settled"]({ draft: "dother" });
  expect(notice()).not.toBeNull();

  handlers["calendar:create-settled"]({ draft });
  expect(notice()).toBeNull();
});

test("Escape dismisses the notice", () => {
  const { hook } = open();
  type("Lunch");
  key(field(), "Enter");
  hook.reconnected();
  expect(notice()).not.toBeNull();

  key(document.body, "Escape");
  expect(notice()).toBeNull();
});

test("Escape on the notice stops there, so a window-level Escape binding does not also fire", () => {
  const { hook } = open();
  type("Lunch");
  key(field(), "Enter");
  hook.reconnected();
  const behind = vi.fn();
  window.addEventListener("keydown", behind);

  key(document.body, "Escape");
  window.removeEventListener("keydown", behind);

  expect(notice()).toBeNull();
  expect(behind).not.toHaveBeenCalled();
});

test("the notice goes with the hook", () => {
  const { hook } = open();
  type("Lunch");
  key(field(), "Enter");
  hook.reconnected();
  expect(notice()).not.toBeNull();

  hook.destroyed();
  expect(notice()).toBeNull();
});

test("a refused create still reopens Save with the server's message", () => {
  const { hook } = open();
  type("Lunch");
  key(field(), "Enter");
  reply(hook, "calendar:create", { accepted: false, field: null, error: "Slow down." });

  expect(hook.draft.status).toBe("editing");
  expect(popover().querySelector("#calendar-qc-error").textContent).toBe("Slow down.");
  expect(popover().querySelector("[data-qc-save]").disabled).toBe(false);
  expect(notice()).toBeNull();
});

test("the fallback native picker keeps focus through its first change", () => {
  const { hook } = open();
  const start = popover().querySelector('[data-qc-input="start"]');
  start.showPicker = undefined;
  popover().querySelector('[data-qc-pick="start"]').click();
  const input = () => popover().querySelector('[data-qc-input="start"]');
  expect(document.activeElement).toBe(input());

  input().value = "11:00";
  input().dispatchEvent(new Event("change", { bubbles: true }));
  expect(hook.draft.start % 1440).toBe(660);
  expect(document.activeElement).toBe(input());
  expect(input().classList.contains("is-open")).toBe(true);
});

test("More options cannot be sent twice, nor followed by a save", () => {
  const { hook } = open();
  type("Planning");
  const more = popover().querySelector("[data-qc-more]");
  more.click();
  popover().querySelector("[data-qc-more]").click();
  key(field(), "Enter");
  popover().querySelector("[data-qc-save]").click();

  expect(pushes(hook, "calendar:more_options")).toHaveLength(1);
  expect(pushes(hook, "calendar:create")).toHaveLength(0);
  expect(popover().querySelector("[data-qc-save]").disabled).toBe(true);
  expect(popover().querySelector("[data-qc-more]").disabled).toBe(true);

  reply(hook, "calendar:more_options", { opened: false });
  expect(hook.draft.status).toBe("editing");
  expect(popover().querySelector("[data-qc-save]").disabled).toBe(false);
});

test("More options with no reply in time unlocks the popover", () => {
  vi.useFakeTimers();
  const { hook } = open();
  popover().querySelector("[data-qc-more]").click();
  vi.advanceTimersByTime(15000);
  expect(hook.draft.status).toBe("editing");
  expect(popover().querySelector("#calendar-qc-error").textContent).toBe(refusal);
});

test("after an accepted save with nothing to return to, focus lands on the grid", () => {
  const { el, hook } = open({ first: payload({ events: [] }) });
  key(field(), "Enter");
  reply(hook, "calendar:create", { accepted: true });
  expect(document.activeElement).toBe(el);
});

test("a press outside after unmount neither throws nor discards", () => {
  const { hook } = open();
  const kept = hook.draft;
  unmountAll();
  expect(() => document.body.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true }))).not.toThrow();
  expect(hook.draft).toBe(kept);
});

test("a refused end on an all-day draft marks the date chip; a title refusal describes the field", () => {
  const { hook } = open();
  popover().querySelector("[data-qc-allday]").click();
  key(field(), "Enter");
  reply(hook, "calendar:create", { accepted: false, field: "end", error: "Too long." });
  expect(popover().querySelector('[data-qc-pick="date"]').getAttribute("aria-invalid")).toBe("true");

  key(field(), "Enter");
  hook.pushEventTo.mock.calls.filter(([, pushed]) => pushed === "calendar:create").at(-1)[3]({ accepted: false, field: "title", error: "Needs a title." });
  expect(field().getAttribute("aria-invalid")).toBe("true");
  expect(field().getAttribute("aria-describedby")).toContain("calendar-qc-error");
});
