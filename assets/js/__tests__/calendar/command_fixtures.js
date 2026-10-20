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

export const commandStrings = {
  weekdays: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
  months: ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"],
  all_day: "All day",
  command_today: "Today",
  command_next: "Next period",
  command_previous: "Previous period",
  command_new_event: "New event",
  command_day: "Day",
  command_three_day: "3 days",
  command_week: "Week",
  command_month: "Month",
  command_agenda: "Agenda",
  command_bookable: "Show or hide bookable times",
  command_show_all: "Show all calendars",
  command_shortcuts: "Keyboard shortcuts",
  command_focus: "Focus mode",
  command_leave_focus: "Leave focus mode",
  command_compact: "Use compact density",
  command_comfortable: "Use comfortable density",
  command_clock_12: "Use the 12-hour clock",
  command_clock_24: "Use the 24-hour clock",
  command_week_sunday: "Start weeks on Sunday",
  command_week_monday: "Start weeks on Monday",
  command_show_weekends: "Show weekends in week view",
  command_hide_weekends: "Hide weekends in week view",
  command_show_week_numbers: "Show week numbers",
  command_hide_week_numbers: "Hide week numbers",
  command_fold: "Fold early hours",
  command_unfold: "Unfold early hours",
  command_reminders_on: "Turn on desktop notifications",
  command_reminders_off: "Turn off desktop notifications",
  command_import: "Import an .ics file",
  command_set: "Switch to %{name}",
  command_leave_set: "Leave the calendar set",
  command_goto: "Go to %{date}",
  command_add: "Add “%{title}”",
};

export const commandSettings = {
  week_start: "monday",
  show_weekends: true,
  density: "comfortable",
  fold_night: true,
  time_format: "24h",
  show_week_numbers: false,
  desktop_reminders: false,
  focus: false,
  sets: [{ position: 1, name: "Work" }, { position: 2, name: "Personal" }],
  active_set: 0,
};
