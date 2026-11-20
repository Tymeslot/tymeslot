/**
 * HTML for the quick-create popover, as pure functions of its state:
 * `{draft, strings, timeFormat, calendars, meetingTypes, hasAccounts}` (calendar/draft.js
 * has the draft's shape, calendar/opening.js the opening's). The hook
 * (hooks/calendar_canvas/create.js) renders the shell once when it opens and
 * the head and body on every change, so the field keeps its caret while the
 * chips follow what was typed.
 *
 * The head is the kind switch, "Event | Open for booking", offered when the
 * organiser has a meeting type to open. An event's chips are real controls:
 * date, start and end open the browser's own picker on a hidden input next
 * to each (on a coarse pointer that input takes the tap itself and is named
 * like its chip, `coarse` in the state), all day is a toggle and the calendar
 * a select. Place and guests come from the text and are shown, not edited,
 * here. An opening hides the field and shows its meeting type, date, start
 * and end, and "Just this once
 * | Every week". Every value the organiser typed is escaped.
 */
import { colour, dateLabel, escapeHtml } from "./render.js";
import { MINUTES_PER_DAY, formatMinutes, isoFromDay } from "./time.js";

const pad = (n) => String(n).padStart(2, "0");
const dayOf = (minute) => Math.floor(minute / MINUTES_PER_DAY);
const clock = (minute) => {
  const rest = ((minute % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY;
  return `${pad(Math.floor(rest / 60))}:${pad(rest % 60)}`;
};
const locked = (draft) => draft.status === "saving" || draft.status === "opening";

// Which chip a refused field belongs to.
const FIELD_CHIPS = { date: ["start", "all_day"], start: ["start"], end: ["end"], calendar: ["calendar"], place: ["location"], guests: ["guests"], meetingType: ["meeting_type"] };

function invalid(chip, error, allDay = false) {
  const named = error?.field && (FIELD_CHIPS[chip]?.includes(error.field) || (chip === "date" && allDay && error.field === "end"));
  return named ? ' aria-invalid="true" aria-describedby="calendar-qc-error"' : "";
}

// On a coarse pointer the native input lies over the chip and takes the tap
// (calendar-editing.css), so assistive technology must reach it too: it
// carries the chip's full name instead of hiding. It stays out of the tab order.
function picker(chip, type, label, text, value, { draft, coarse = false }, parsed) {
  const name = coarse ? `${label}: ${text}` : label;
  return (
    `<span class="cal-qc-chip-wrap">` +
    `<button type="button" class="cal-qc-chip${parsed ? " is-parsed" : ""}" data-qc-pick="${chip}" data-qc-key="${chip}" aria-label="${escapeHtml(`${label}: ${text}`)}"${invalid(chip, draft.error, draft.allDay)}>${escapeHtml(text)}</button>` +
    `<input class="cal-qc-native" type="${type}" data-qc-input="${chip}" data-qc-key="${chip}-input" value="${escapeHtml(value)}" tabindex="-1"${coarse ? "" : ' aria-hidden="true"'} aria-label="${escapeHtml(name)}"${type === "time" ? ' step="900"' : ""}>` +
    `</span>`
  );
}

function dateText(draft, strings) {
  const first = dayOf(draft.start);
  const last = draft.allDay ? Math.max(first, dayOf(draft.end) - 1) : first;
  const label = dateLabel(isoFromDay(first), strings);
  return last > first ? `${label} – ${dateLabel(isoFromDay(last), strings)}` : label;
}

// Date, start and end, shared by both kinds.
function whenChips(state, found = {}) {
  const { draft, strings, timeFormat } = state;
  let html = picker("date", "date", strings.date_chip, dateText(draft, strings), isoFromDay(dayOf(draft.start)), state, found.date);
  if (!draft.allDay) {
    html +=
      picker("start", "time", strings.start_chip, formatMinutes(draft.start % MINUTES_PER_DAY, timeFormat), clock(draft.start), state, found.time) +
      `<span class="cal-qc-sep" aria-hidden="true">${escapeHtml(strings.time_to)}</span>` +
      picker("end", "time", strings.end_chip, formatMinutes(draft.end % MINUTES_PER_DAY, timeFormat), clock(draft.end), state, found.time);
  }
  return html;
}

function calendarChip({ draft, strings, calendars }) {
  if (!calendars.length) return "";
  const current = calendars.find((c) => c.key === draft.calendar) || calendars[0];
  const named = (c) => (calendars.filter((other) => other.name === c.name).length > 1 && c.account ? `${c.name} · ${c.account}` : c.name);
  const options = calendars.map((c) => `<option value="${escapeHtml(c.key)}"${c.key === current.key ? " selected" : ""}>${escapeHtml(named(c))}</option>`).join("");
  return (
    `<label class="cal-qc-chip cal-qc-calendar${draft.found?.calendar ? " is-parsed" : ""}" style="--cal-ev:${colour(current.colour)}">` +
    `<span class="cal-qc-dot" aria-hidden="true"></span>` +
    `<select data-qc-input="calendar" data-qc-key="calendar" aria-label="${escapeHtml(strings.calendar_chip)}"${invalid("calendar", draft.error)}>${options}</select></label>`
  );
}

function textChip(chip, label, text, error) {
  return `<span class="cal-qc-chip is-parsed" title="${escapeHtml(text)}"${invalid(chip, error)}><span class="sr-only">${escapeHtml(label)}: </span>${escapeHtml(text)}</span>`;
}

function chips(state) {
  const { draft, strings } = state;
  const found = draft.found || {};
  let html = whenChips(state, found);
  html += `<button type="button" class="cal-qc-chip${draft.allDay && found.time ? " is-parsed" : ""}" data-qc-allday data-qc-key="allday" aria-pressed="${draft.allDay}">${escapeHtml(strings.all_day_chip)}</button>`;
  html += calendarChip(state);
  if (draft.location) html += textChip("place", strings.place_chip, draft.location, draft.error);
  if (draft.guests.length) html += textChip("guests", strings.guests_chip, draft.guests.join(", "), draft.error);
  return `<div class="cal-qc-chips">${html}</div>`;
}

function openChips(state) {
  const { draft, strings, meetingTypes } = state;
  const current = meetingTypes.find((type) => type.id === draft.meetingType) || meetingTypes[0];
  const options = meetingTypes.map((type) => `<option value="${escapeHtml(String(type.id))}"${type === current ? " selected" : ""}>${escapeHtml(type.name)}</option>`).join("");
  return (
    `<div class="cal-qc-chips">` +
    `<label class="cal-qc-chip cal-qc-type"><select data-qc-input="meetingType" data-qc-key="meeting-type" aria-label="${escapeHtml(strings.meeting_type_chip)}"${invalid("meetingType", draft.error)}>${options}</select></label>` +
    whenChips(state) +
    `</div>`
  );
}

function showAs({ draft, strings }) {
  const option = (free, label) =>
    `<button type="button" data-qc-free="${free}" data-qc-key="${free ? "free" : "busy"}" aria-pressed="${draft.free === free}">${escapeHtml(label)}</button>`;
  return (
    `<div class="cal-qc-row"><span class="cal-qc-label" id="calendar-qc-show-as">${escapeHtml(strings.show_as)}</span>` +
    `<div class="cal-qc-seg" role="group" aria-labelledby="calendar-qc-show-as">${option(false, strings.busy)}${option(true, strings.free)}</div></div>`
  );
}

function repeatRow({ draft, strings }) {
  const option = (repeat, label) =>
    `<button type="button" data-qc-repeat="${repeat}" data-qc-key="repeat-${repeat}" aria-pressed="${draft.repeat === repeat}">${escapeHtml(label)}</button>`;
  return (
    `<div class="cal-qc-row"><span class="cal-qc-label" id="calendar-qc-repeat">${escapeHtml(strings.repeat_label)}</span>` +
    `<div class="cal-qc-seg" role="group" aria-labelledby="calendar-qc-repeat">${option("once", strings.just_this_once)}${option("weekly", strings.every_week)}</div></div>`
  );
}

function saveLabel({ draft, strings }) {
  if (draft.status === "saving") return strings.saving_draft;
  return draft.guests.length ? strings.save_and_invite : strings.save;
}

function errorLine(draft) {
  return draft.error ? `<p id="calendar-qc-error" class="cal-qc-error" role="alert">${escapeHtml(draft.error.message)}</p>` : "";
}

const NO_CALENDAR_ID = "calendar-qc-no-calendar";

// Without a calendar Save is off, but More options stays: the panel can
// still send the draft as a Tymeslot meeting, which needs no calendar.
function foot({ draft, strings }, label, { more, blocked = false }) {
  const lock = locked(draft) ? " disabled" : "";
  const off = (locked(draft) || blocked ? " disabled" : "") + (blocked ? ` aria-describedby="${NO_CALENDAR_ID}"` : "");
  return (
    `<div class="cal-qc-foot">` +
    (more ? `<button type="button" class="cal-qc-more" data-qc-more data-qc-key="more"${lock}>${escapeHtml(strings.more_options)}</button>` : "") +
    `<button type="button" class="cal-qc-save action-button action-button--primary action-button--sm" data-qc-save data-qc-key="save"${off}>${escapeHtml(label)}</button>` +
    `</div>`
  );
}

const hint = (text) => `<p id="calendar-qc-hint" class="cal-qc-hint">${escapeHtml(text)}</p>`;

// Without a calendar to write to, an event cannot be saved; the note says why.
function eventBody(state) {
  const blocked = !state.calendars.length;
  const text = state.hasAccounts ? state.strings.read_only_calendars_note : state.strings.no_calendar_note;
  const note = blocked ? `<p id="${NO_CALENDAR_ID}" class="cal-qc-note" role="note">${escapeHtml(text)}</p>` : "";
  return chips(state) + showAs(state) + note + errorLine(state.draft) + foot(state, saveLabel(state), { more: true, blocked }) + hint(state.strings.quick_create_hint);
}

function openBody(state) {
  const { draft, strings } = state;
  const label = draft.status === "saving" ? strings.saving_draft : strings.open_save;
  return openChips(state) + repeatRow(state) + errorLine(draft) + foot(state, label, { more: false }) + hint(strings.open_hint);
}

const opening = (state) => state.draft.kind === "open" && (state.meetingTypes || []).length > 0;

// The kind switch above the field; nothing without a meeting type to open.
export function renderQuickHead({ draft, strings, meetingTypes = [] }) {
  if (!meetingTypes.length) return "";
  const off = locked(draft) ? " disabled" : "";
  const option = (kind, label) => `<button type="button" data-qc-kind="${kind}" data-qc-key="kind-${kind}" aria-pressed="${draft.kind === kind}"${off}>${escapeHtml(label)}</button>`;
  return `<div class="cal-qc-seg cal-qc-kind" role="group" aria-label="${escapeHtml(strings.kind_label)}">${option("event", strings.kind_event)}${option("open", strings.kind_open)}</div>`;
}

// Everything under the field; re-rendered on every change.
export function renderQuickBody(state) {
  return opening(state) ? openBody(state) : eventBody(state);
}

// The field is described by the hint, and by why saving is off when it is.
const fieldDescribedBy = ({ calendars }) => (calendars.length ? "calendar-qc-hint" : `calendar-qc-hint ${NO_CALENDAR_ID}`);

// The whole popover, rendered once when it opens.
export function renderQuickCreate(state) {
  const { draft, strings } = state;
  return (
    `<div id="calendar-quick-create" class="cal-qc" role="dialog" aria-modal="false" aria-labelledby="calendar-qc-title">` +
    `<h2 id="calendar-qc-title" class="sr-only">${escapeHtml(strings.quick_create_label)}</h2>` +
    `<div class="cal-qc-head" data-qc-head>${renderQuickHead(state)}</div>` +
    `<label for="calendar-qc-field" class="sr-only">${escapeHtml(strings.quick_create_label)}</label>` +
    `<input id="calendar-qc-field" class="cal-qc-field" type="text" autocomplete="off" enterkeyhint="done" ` +
    `placeholder="${escapeHtml(strings.quick_create_placeholder)}" aria-describedby="${fieldDescribedBy(state)}" value="${escapeHtml(draft.text)}"${opening(state) ? " hidden" : ""}>` +
    `<div class="cal-qc-body" data-qc-body>${renderQuickBody(state)}</div>` +
    `</div>`
  );
}
