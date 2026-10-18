/**
 * HTML for the quick-create popover, as pure functions of its state:
 * `{draft, strings, timeFormat, calendars}` (calendar/draft.js has the
 * draft's shape). The hook (hooks/calendar_canvas/create.js) renders the
 * shell once when it opens and the body on every change, so the field keeps
 * its caret while the chips follow what was typed.
 *
 * The chips are real controls: date, start and end open the browser's own
 * picker on a hidden input next to each, all day is a toggle and the
 * calendar a select. Place and guests come from the text and are shown, not
 * edited, here. Every value the organiser typed is escaped.
 */
import { colour, dateLabel, escapeHtml } from "./render.js";
import { MINUTES_PER_DAY, formatMinutes, isoFromDay } from "./time.js";

const pad = (n) => String(n).padStart(2, "0");
const dayOf = (minute) => Math.floor(minute / MINUTES_PER_DAY);
const clock = (minute) => {
  const rest = ((minute % MINUTES_PER_DAY) + MINUTES_PER_DAY) % MINUTES_PER_DAY;
  return `${pad(Math.floor(rest / 60))}:${pad(rest % 60)}`;
};

// Which chip a refused field belongs to.
const FIELD_CHIPS = { date: ["start", "all_day"], start: ["start"], end: ["end"], calendar: ["calendar"], place: ["location"], guests: ["guests"] };

function invalid(chip, error, allDay = false) {
  const named = error?.field && (FIELD_CHIPS[chip]?.includes(error.field) || (chip === "date" && allDay && error.field === "end"));
  return named ? ' aria-invalid="true" aria-describedby="calendar-qc-error"' : "";
}

function picker(chip, type, label, text, value, { draft }, parsed) {
  return (
    `<span class="cal-qc-chip-wrap">` +
    `<button type="button" class="cal-qc-chip${parsed ? " is-parsed" : ""}" data-qc-pick="${chip}" data-qc-key="${chip}" aria-label="${escapeHtml(`${label}: ${text}`)}"${invalid(chip, draft.error, draft.allDay)}>${escapeHtml(text)}</button>` +
    `<input class="cal-qc-native" type="${type}" data-qc-input="${chip}" data-qc-key="${chip}-input" value="${escapeHtml(value)}" tabindex="-1" aria-hidden="true" aria-label="${escapeHtml(label)}"${type === "time" ? ' step="900"' : ""}>` +
    `</span>`
  );
}

function dateText(draft, strings) {
  const first = dayOf(draft.start);
  const last = draft.allDay ? Math.max(first, dayOf(draft.end) - 1) : first;
  const label = dateLabel(isoFromDay(first), strings);
  return last > first ? `${label} – ${dateLabel(isoFromDay(last), strings)}` : label;
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
  const { draft, strings, timeFormat } = state;
  const found = draft.found || {};
  let html = picker("date", "date", strings.date_chip, dateText(draft, strings), isoFromDay(dayOf(draft.start)), state, found.date);
  if (!draft.allDay) {
    html +=
      picker("start", "time", strings.start_chip, formatMinutes(draft.start % MINUTES_PER_DAY, timeFormat), clock(draft.start), state, found.time) +
      `<span class="cal-qc-sep" aria-hidden="true">${escapeHtml(strings.time_to)}</span>` +
      picker("end", "time", strings.end_chip, formatMinutes(draft.end % MINUTES_PER_DAY, timeFormat), clock(draft.end), state, found.time);
  }
  html += `<button type="button" class="cal-qc-chip${draft.allDay && found.time ? " is-parsed" : ""}" data-qc-allday data-qc-key="allday" aria-pressed="${draft.allDay}">${escapeHtml(strings.all_day_chip)}</button>`;
  html += calendarChip(state);
  if (draft.location) html += textChip("place", strings.place_chip, draft.location, draft.error);
  if (draft.guests.length) html += textChip("guests", strings.guests_chip, draft.guests.join(", "), draft.error);
  return `<div class="cal-qc-chips">${html}</div>`;
}

function showAs({ draft, strings }) {
  const option = (free, label) =>
    `<button type="button" data-qc-free="${free}" data-qc-key="${free ? "free" : "busy"}" aria-pressed="${draft.free === free}">${escapeHtml(label)}</button>`;
  return (
    `<div class="cal-qc-row"><span class="cal-qc-label" id="calendar-qc-show-as">${escapeHtml(strings.show_as)}</span>` +
    `<div class="cal-qc-seg" role="group" aria-labelledby="calendar-qc-show-as">${option(false, strings.busy)}${option(true, strings.free)}</div></div>`
  );
}

function saveLabel({ draft, strings }) {
  if (draft.status === "saving") return strings.saving_draft;
  return draft.guests.length ? strings.save_and_invite : strings.save;
}

// Everything under the field; re-rendered on every change.
export function renderQuickBody(state) {
  const { draft, strings } = state;
  const locked = draft.status === "saving" || draft.status === "opening";
  return (
    chips(state) +
    showAs(state) +
    (draft.error ? `<p id="calendar-qc-error" class="cal-qc-error" role="alert">${escapeHtml(draft.error.message)}</p>` : "") +
    `<div class="cal-qc-foot">` +
    `<button type="button" class="cal-qc-more" data-qc-more data-qc-key="more"${locked ? " disabled" : ""}>${escapeHtml(strings.more_options)}</button>` +
    `<button type="button" class="cal-qc-save action-button action-button--primary action-button--sm" data-qc-save data-qc-key="save"${locked ? " disabled" : ""}>${escapeHtml(saveLabel(state))}</button>` +
    `</div>` +
    `<p id="calendar-qc-hint" class="cal-qc-hint">${escapeHtml(strings.quick_create_hint)}</p>`
  );
}

// The whole popover, rendered once when it opens.
export function renderQuickCreate(state) {
  const { draft, strings } = state;
  return (
    `<div id="calendar-quick-create" class="cal-qc" role="dialog" aria-modal="false" aria-labelledby="calendar-qc-title">` +
    `<h2 id="calendar-qc-title" class="sr-only">${escapeHtml(strings.quick_create_label)}</h2>` +
    `<label for="calendar-qc-field" class="sr-only">${escapeHtml(strings.quick_create_label)}</label>` +
    `<input id="calendar-qc-field" class="cal-qc-field" type="text" autocomplete="off" enterkeyhint="done" ` +
    `placeholder="${escapeHtml(strings.quick_create_placeholder)}" aria-describedby="calendar-qc-hint" value="${escapeHtml(draft.text)}">` +
    `<div class="cal-qc-body" data-qc-body>${renderQuickBody(state)}</div>` +
    `</div>`
  );
}
