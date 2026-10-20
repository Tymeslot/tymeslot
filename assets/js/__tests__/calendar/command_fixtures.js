/**
 * Fixtures for the command bar's hook tests: the markup CommandBar renders
 * (with the toolbar's search button and a field elsewhere on the page), a
 * server search row, and the hook mounted beside them with a stand-in for
 * `liveSocket.execJS` that runs the bar's show and hide commands.
 */
import { vi } from "vitest";
import { mountHook } from "./canvas_harness.js";

const BAR = `
  <div id="calendar-command" class="cal-command" role="dialog" aria-modal="true" data-show="show" data-hide="hide">
    <div class="cal-command-scrim" data-command-scrim></div>
    <form id="calendar-command-form">
      <input id="calendar-command-input" name="q" type="text" role="combobox">
      <button type="button" data-command-close>Close</button>
    </form>
    <div id="calendar-command-list" role="listbox">
      <div id="calendar-command-instant" role="group"></div>
      <div id="calendar-command-results" role="group"></div>
      <div id="calendar-command-after" role="group"></div>
    </div>
  </div>
  <button id="calendar-search" type="button">Search</button>
  <input id="outside-field" type="text">`;

export const result = (id, date, startMin = 660) =>
  `<button type="button" role="option" tabindex="-1" id="calendar-command-row-${id}" data-command-result data-reveal-ids="${id}" data-date="${date}" data-start-min="${startMin}" data-all-day="false">${id}</button>`;

// The bar must be in the page before the hook mounts (its observer watches it).
export function mountWithBar(first) {
  document.body.insertAdjacentHTML("beforeend", BAR);
  const mounted = mountHook(first);
  mounted.hook.liveSocket = {
    execJS: vi.fn((el, js) => (js === "show" ? el.setAttribute("data-open", "true") : el.removeAttribute("data-open"))),
  };
  mounted.hook.pushEvent = vi.fn();
  return {
    ...mounted,
    bar: document.getElementById("calendar-command"),
    input: document.getElementById("calendar-command-input"),
    results: document.getElementById("calendar-command-results"),
  };
}
