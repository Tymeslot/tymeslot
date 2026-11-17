/**
 * Tests for the quick-create popover's HTML (calendar/quick_create.js):
 * chips for what the draft holds, the Busy/Free control, the Save label,
 * a refusal, and escaping of everything typed.
 */
import { expect, test } from "vitest";
import { applyChip, applyText, draftFromSlot } from "../../calendar/draft.js";
import { renderQuickBody, renderQuickCreate } from "../../calendar/quick_create.js";
import { dayNumber } from "../../calendar/time.js";
import { calendars, strings } from "./canvas_harness.js";

const opts = { today: "2026-10-18", calendars };
const base = () => draftFromSlot("d1", { day: dayNumber("2026-10-20"), minute: 600 }, "7:work");

function view(draft, extra = {}) {
  const holder = document.createElement("div");
  holder.innerHTML = renderQuickCreate({ draft, strings, timeFormat: "24h", calendars, ...extra });
  return holder.firstElementChild;
}

test("the popover is a labelled dialog with one field", () => {
  const popover = view(base());
  expect(popover.getAttribute("role")).toBe("dialog");
  expect(popover.querySelector(`#${popover.getAttribute("aria-labelledby")}`).textContent).toBe("New event");
  const field = popover.querySelector("#calendar-qc-field");
  expect(field.getAttribute("placeholder")).toBe("Title, or: lunch 13:00 /personal");
  expect(popover.querySelector('label[for="calendar-qc-field"]')).not.toBeNull();
  expect(popover.querySelector("#calendar-qc-hint").textContent).toMatch(/^Enter saves/);
});

test("date, start and end chips show the draft and carry native inputs", () => {
  const popover = view(base());
  const chip = (name) => popover.querySelector(`[data-qc-pick="${name}"]`);
  expect(chip("date").textContent).toBe("Tue 20 Oct");
  expect(chip("start").getAttribute("aria-label")).toBe("Starts: 10:00");
  expect(chip("end").textContent).toBe("10:30");
  expect(popover.querySelector('[data-qc-input="date"]').value).toBe("2026-10-20");
  expect(popover.querySelector('[data-qc-input="start"]').getAttribute("step")).toBe("900");
  expect(popover.querySelector('[data-qc-input="end"]').getAttribute("tabindex")).toBe("-1");
});

test("12-hour organisers see 12-hour chips, while the inputs keep 24-hour values", () => {
  const popover = view(applyChip(base(), "start", "14:00"), { timeFormat: "12h" });
  expect(popover.querySelector('[data-qc-pick="start"]').textContent).toBe("2:00 PM");
  expect(popover.querySelector('[data-qc-input="start"]').value).toBe("14:00");
});

test("an all-day draft has no time chips and its toggle is pressed", () => {
  const popover = view(applyChip(base(), "allDay", true));
  expect(popover.querySelector('[data-qc-pick="start"]')).toBeNull();
  expect(popover.querySelector("[data-qc-allday]").getAttribute("aria-pressed")).toBe("true");
});

test("a multi-day all-day draft names its first and last day", () => {
  const popover = view(applyText(base(), "retreat fri-sun", opts));
  expect(popover.querySelector('[data-qc-pick="date"]').textContent).toBe("Fri 23 Oct – Sun 25 Oct");
});

test("the calendar select lists the writable calendars with the draft's selected", () => {
  const popover = view(applyText(base(), "gym /personal", opts));
  const select = popover.querySelector('select[data-qc-input="calendar"]');
  expect([...select.options].map((o) => [o.value, o.textContent])).toEqual([
    ["7:work", "Work"],
    ["7:personal", "Personal"],
  ]);
  expect(select.value).toBe("7:personal");
  expect(select.closest("label").classList.contains("is-parsed")).toBe(true);
});

test("calendars with the same name are told apart by account", () => {
  const twins = [
    { key: "1:a", name: "Work", account: "anna@example.com", colour: "calendar-1" },
    { key: "2:b", name: "Work", account: "anna@company.com", colour: "calendar-2" },
  ];
  const popover = view({ ...base(), calendar: "2:b" }, { calendars: twins });
  expect([...popover.querySelectorAll("option")].map((o) => o.textContent)).toEqual(["Work · anna@example.com", "Work · anna@company.com"]);
});

test("without a writable calendar there is no calendar chip", () => {
  expect(view(base(), { calendars: [] }).querySelector("select")).toBeNull();
});

test("place and guests show as chips; guests turn Save into Save and invite", () => {
  const popover = view(applyText(base(), "1:1 ;Room 4 @anna@example.com", opts));
  const texts = [...popover.querySelectorAll(".cal-qc-chip.is-parsed")].map((c) => c.textContent);
  expect(texts).toContain("Place: Room 4");
  expect(texts).toContain("Guests: anna@example.com");
  // A chip too long for the popover is cut with an ellipsis; its title keeps the whole text.
  const titles = [...popover.querySelectorAll("span.cal-qc-chip")].map((c) => c.getAttribute("title"));
  expect(titles).toEqual(expect.arrayContaining(["Room 4", "anna@example.com"]));
  expect(popover.querySelector("[data-qc-save]").textContent).toBe("Save and invite");
  expect(view(base()).querySelector("[data-qc-save]").textContent).toBe("Save");
});

test("Busy and Free are a pressed pair", () => {
  const busy = view(base());
  expect(busy.querySelector('[data-qc-free="false"]').getAttribute("aria-pressed")).toBe("true");
  const free = view(applyChip(base(), "free", true));
  expect(free.querySelector('[data-qc-free="true"]').getAttribute("aria-pressed")).toBe("true");
  expect(free.querySelector('[role="group"]').getAttribute("aria-labelledby")).toBe("calendar-qc-show-as");
});

test("while saving, Save reads Saving… and both buttons are disabled", () => {
  const popover = view({ ...base(), status: "saving" });
  expect(popover.querySelector("[data-qc-save]").textContent).toBe("Saving…");
  expect(popover.querySelector("[data-qc-save]").disabled).toBe(true);
  expect(popover.querySelector("[data-qc-more]").disabled).toBe(true);
});

test("a refusal naming a field marks its chip; one naming none stands alone", () => {
  const named = view({ ...base(), error: { field: "end", message: "The end must be after the start." } });
  expect(named.querySelector("#calendar-qc-error").textContent).toBe("The end must be after the start.");
  expect(named.querySelector("#calendar-qc-error").getAttribute("role")).toBe("alert");
  expect(named.querySelector('[data-qc-pick="end"]').getAttribute("aria-invalid")).toBe("true");
  expect(named.querySelector('[data-qc-pick="start"]').hasAttribute("aria-invalid")).toBe(false);

  const unnamed = view({ ...base(), error: { field: null, message: "Too many new events at once." } });
  expect(unnamed.querySelector("#calendar-qc-error").textContent).toBe("Too many new events at once.");
  expect(unnamed.querySelectorAll('[aria-invalid="true"]')).toHaveLength(0);
});

test("everything typed is escaped", () => {
  const draft = applyText(base(), '<b>x</b> ;<img src=x onerror=alert(1)> @a"b@x.io', opts);
  const holder = document.createElement("div");
  holder.innerHTML = renderQuickCreate({ draft, strings, timeFormat: "24h", calendars });
  expect(holder.querySelector("b, img")).toBeNull();
  expect(holder.querySelector("#calendar-qc-field").value).toBe(draft.text);
  expect(renderQuickBody({ draft: { ...draft, error: { field: null, message: "<i>no</i>" } }, strings, timeFormat: "24h", calendars })).toContain("&lt;i&gt;no&lt;/i&gt;");
});

test("a refused end on an all-day draft marks the date chip", () => {
  const popover = view({ ...applyChip(base(), "allDay", true), error: { field: "end", message: "Too long." } });
  expect(popover.querySelector('[data-qc-pick="date"]').getAttribute("aria-invalid")).toBe("true");
});

test("the native inputs have their own focus key", () => {
  expect(view(base()).querySelector('[data-qc-input="start"]').getAttribute("data-qc-key")).toBe("start-input");
});

test("on a coarse pointer the native inputs, which take the tap, are named like their chips and not hidden", () => {
  const touch = view(base(), { coarse: true });
  const start = touch.querySelector('[data-qc-input="start"]');
  expect(start.hasAttribute("aria-hidden")).toBe(false);
  expect(start.getAttribute("aria-label")).toBe("Starts: 10:00");
  expect(start.getAttribute("tabindex")).toBe("-1");

  const mouse = view(base()).querySelector('[data-qc-input="start"]');
  expect(mouse.getAttribute("aria-hidden")).toBe("true");
});
