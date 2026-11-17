/**
 * Pins the "+N" list's move into hooks/calendar_canvas/list.js: the hook
 * takes it from ListMixin, and it opens, toggles and closes as before. The
 * list's other behaviour stays covered by calendar_canvas.test.js and the
 * bookable, views and sheets hook tests.
 */
import { afterEach, expect, test } from "vitest";
import { CalendarCanvas } from "../../hooks/calendar_canvas.js";
import { ListMixin } from "../../hooks/calendar_canvas/list.js";
import { block, mountHook, unmountAll } from "./canvas_harness.js";

afterEach(() => unmountAll());

const twoEvents = (hook) => [hook.cache.events.get("event-2"), hook.cache.events.get("event-1")];

test("the hook takes its +N list from ListMixin", () => {
  for (const name of ["mountList", "destroyList", "showList", "dropList", "closeList"]) {
    expect(typeof ListMixin[name]).toBe("function");
    expect(CalendarCanvas[name]).toBe(ListMixin[name]);
  }
});

test("a list opens in start order with focus on its first event, and a second press on its anchor closes it", () => {
  const { el, hook } = mountHook();
  const anchor = block(el, "event-1");

  hook.showList(twoEvents(hook), anchor, "Events at this time");

  const items = el.querySelectorAll(".cal-list .cal-list-item");
  expect(items).toHaveLength(2);
  expect(items[0].textContent).toContain("Design review");
  expect(document.activeElement).toBe(el.querySelector(".cal-list button"));

  hook.showList(twoEvents(hook), anchor, "Events at this time");
  expect(el.querySelector(".cal-list")).toBeNull();
});

test("a press outside closes the list and hands focus back to its anchor", () => {
  const { el, hook } = mountHook();
  hook.showList(twoEvents(hook), block(el, "event-1"), "Events at this time");

  document.body.dispatchEvent(new Event("pointerdown", { bubbles: true }));

  expect(el.querySelector(".cal-list")).toBeNull();
  expect(document.activeElement.dataset.eventId).toBe("event-1");
});
