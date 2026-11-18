/**
 * Tests for the quick-create popover's kind switch and "Open for booking"
 * body (calendar/quick_create.js): offered only with meeting types, the
 * opening's chips and repeat choice, its Save, refusals on the right chip,
 * and escaping of meeting type names.
 */
import { expect, test } from "vitest";
import { draftFromSlot } from "../../calendar/draft.js";
import { withKind } from "../../calendar/opening.js";
import { renderQuickCreate } from "../../calendar/quick_create.js";
import { dayNumber } from "../../calendar/time.js";
import { calendars, strings } from "./canvas_harness.js";

const meetingTypes = [
  { id: 11, name: "Intro call", duration: 30 },
  { id: 12, name: "<b>Deep</b> dive", duration: 90 },
];
const event = () => draftFromSlot("d1", { day: dayNumber("2026-10-20"), minute: 600 }, "7:work");
const opening = (extra = {}) => ({ ...withKind(event(), "open", meetingTypes), ...extra });

function view(draft, types = meetingTypes) {
  const holder = document.createElement("div");
  holder.innerHTML = renderQuickCreate({ draft, strings, timeFormat: "24h", calendars, meetingTypes: types });
  return holder.firstElementChild;
}

test("without meeting types there is no kind switch", () => {
  const popover = view(event(), []);
  expect(popover.querySelector("[data-qc-kind]")).toBeNull();
  expect(popover.querySelector("[data-qc-head]").innerHTML).toBe("");
});

test("the kind switch is a labelled group above the field", () => {
  const popover = view(event());
  const group = popover.querySelector(".cal-qc-kind");
  expect(group.getAttribute("role")).toBe("group");
  expect(group.getAttribute("aria-label")).toBe("What to add");
  const kinds = [...group.querySelectorAll("[data-qc-kind]")].map((b) => [b.dataset.qcKind, b.textContent, b.getAttribute("aria-pressed")]);
  expect(kinds).toEqual([
    ["event", "Event", "true"],
    ["open", "Open for booking", "false"],
  ]);
  const field = popover.querySelector("#calendar-qc-field");
  expect(group.compareDocumentPosition(field) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
});

test("an event keeps its chips, Busy/Free and More options", () => {
  const popover = view(event());
  expect(popover.querySelector("#calendar-qc-field").hidden).toBe(false);
  expect(popover.querySelector("[data-qc-allday]")).not.toBeNull();
  expect(popover.querySelector("[data-qc-free]")).not.toBeNull();
  expect(popover.querySelector("[data-qc-more]")).not.toBeNull();
  expect(popover.querySelector("[data-qc-input='meetingType']")).toBeNull();
});

test("an opening hides the field and shows the meeting type, date, times and how often", () => {
  const popover = view(opening());
  expect(popover.querySelector("#calendar-qc-field").hidden).toBe(true);
  const select = popover.querySelector("[data-qc-input='meetingType']");
  expect(select.getAttribute("aria-label")).toBe("Meeting type");
  expect(select.value).toBe("11");
  expect(popover.querySelector("[data-qc-pick='date']").textContent).toBe("Tue 20 Oct");
  expect(popover.querySelector("[data-qc-pick='start']").textContent).toBe("10:00");
  expect(popover.querySelector("[data-qc-pick='end']").textContent).toBe("10:30");
  const repeats = [...popover.querySelectorAll("[data-qc-repeat]")].map((b) => [b.textContent, b.getAttribute("aria-pressed")]);
  expect(repeats).toEqual([
    ["Just this once", "true"],
    ["Every week", "false"],
  ]);
  for (const gone of ["[data-qc-allday]", "[data-qc-free]", "[data-qc-more]", "[data-qc-input='calendar']"]) expect(popover.querySelector(gone)).toBeNull();
  expect(popover.querySelector("[data-qc-save]").textContent).toBe("Open for booking");
  expect(popover.querySelector("#calendar-qc-hint").textContent).toMatch(/^Guests can book this time/);
});

test("every week is shown as chosen", () => {
  const popover = view(opening({ repeat: "weekly" }));
  expect(popover.querySelector("[data-qc-repeat='weekly']").getAttribute("aria-pressed")).toBe("true");
});

test("meeting type names are escaped", () => {
  const popover = view(opening());
  const option = popover.querySelector("option[value='12']");
  expect(option.textContent).toBe("<b>Deep</b> dive");
  expect(option.querySelector("b")).toBeNull();
});

test("saving locks the kind switch and the Save button", () => {
  const popover = view(opening({ status: "saving" }));
  expect(popover.querySelector("[data-qc-save]").textContent).toBe("Saving…");
  expect(popover.querySelector("[data-qc-save]").disabled).toBe(true);
  expect(popover.querySelector("[data-qc-kind='event']").disabled).toBe(true);
});

test("a refusal marks the chip it names", () => {
  const typeRefused = view(opening({ error: { field: "meeting_type", message: "That meeting type can't be opened. Choose another one." } }));
  expect(typeRefused.querySelector("#calendar-qc-error").textContent).toBe("That meeting type can't be opened. Choose another one.");
  expect(typeRefused.querySelector("[data-qc-input='meetingType']").getAttribute("aria-invalid")).toBe("true");

  const startRefused = view(opening({ error: { field: "start", message: "That time has passed. Choose a later one." } }));
  expect(startRefused.querySelector("[data-qc-pick='start']").getAttribute("aria-invalid")).toBe("true");
  expect(startRefused.querySelector("[data-qc-input='meetingType']").hasAttribute("aria-invalid")).toBe(false);
});

test("with no calendar to write to, an event explains why it can't be saved", () => {
  const holder = document.createElement("div");
  holder.innerHTML = renderQuickCreate({ draft: { ...event(), calendar: null }, strings, timeFormat: "24h", calendars: [], meetingTypes });
  const popover = holder.firstElementChild;

  expect(popover.querySelector("#calendar-qc-no-calendar").textContent).toBe("Connect a calendar to add events, or use More options to send a Tymeslot meeting.");
  expect(popover.querySelector("[data-qc-save]").disabled).toBe(true);
  // The panel can still send it as a Tymeslot meeting, which needs no calendar.
  expect(popover.querySelector("[data-qc-more]").disabled).toBe(false);
});

test("with a calendar there is no such note", () => {
  expect(view(event()).querySelector("#calendar-qc-no-calendar")).toBeNull();
  expect(view(opening(), meetingTypes).querySelector("#calendar-qc-no-calendar")).toBeNull();
});

function noCalendarView(extra = {}) {
  const holder = document.createElement("div");
  holder.innerHTML = renderQuickCreate({ draft: { ...event(), calendar: null }, strings, timeFormat: "24h", calendars: [], meetingTypes, ...extra });
  return holder.firstElementChild;
}

test("the note is wired to the field and Save", () => {
  const popover = noCalendarView();
  const note = popover.querySelector("#calendar-qc-no-calendar");

  expect(note.getAttribute("role")).toBe("note");
  expect(popover.querySelector("#calendar-qc-field").getAttribute("aria-describedby")).toBe("calendar-qc-hint calendar-qc-no-calendar");
  expect(popover.querySelector("[data-qc-save]").getAttribute("aria-describedby")).toBe("calendar-qc-no-calendar");
  expect(popover.querySelector("[data-qc-more]").hasAttribute("aria-describedby")).toBe(false);
});

test("with a calendar nothing points at a note", () => {
  const popover = view(event());
  expect(popover.querySelector("#calendar-qc-field").getAttribute("aria-describedby")).toBe("calendar-qc-hint");
  expect(popover.querySelector("[data-qc-save]").hasAttribute("aria-describedby")).toBe(false);
});

test("connected calendars that are all read-only say so instead of asking to connect one", () => {
  const note = noCalendarView({ hasAccounts: true }).querySelector("#calendar-qc-no-calendar");
  expect(note.textContent).toBe("Your calendars are read-only. Connect one you can write to, or use More options to send a Tymeslot meeting.");
});
