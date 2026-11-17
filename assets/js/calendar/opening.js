/**
 * "Open for booking" in quick create, as pure functions of the draft
 * (calendar/draft.js has its shape). An opening has `kind: "open"`, the
 * meeting type it opens (`meetingType`, an id from `settings.meeting_types`)
 * and how often (`repeat`: "once" or "weekly"). It is always timed, and at
 * least as long as its meeting type, since a shorter opening could hold no
 * meeting. Switching back to an event keeps the time.
 */
import { applyChip, nextSlot, rebased } from "./draft.js";
import { interpolate } from "./render.js";
import { MINUTES_PER_DAY, formatWall, isoFromDay, parseWall } from "./time.js";

const REPEATS = ["once", "weekly"];

const typeOf = (meetingTypes, id) => meetingTypes.find((type) => String(type.id) === String(id));

// At least `minutes` long, from the same start.
function atLeast(draft, minutes) {
  if (!minutes || draft.end - draft.start >= minutes) return draft;
  return rebased({ ...draft, end: draft.start + minutes });
}

// The draft as kind `kind` ("event" or "open"). An opening needs a meeting
// type to open, so without one the draft stays as it was.
export function withKind(draft, kind, meetingTypes) {
  if (kind === "event") return { ...draft, kind: "event", error: null };
  if (kind !== "open" || !meetingTypes.length) return draft;
  const timed = draft.allDay ? applyChip(draft, "allDay", false) : draft;
  const type = typeOf(meetingTypes, timed.meetingType) || meetingTypes[0];
  return atLeast({ ...timed, kind: "open", meetingType: type.id, error: null }, type.duration);
}

// The opening after its meeting type ("meetingType", an id as the select
// gives it) or "repeat" changed. A value the controls cannot produce
// changes nothing.
export function applyOpening(draft, chip, value, meetingTypes) {
  if (chip === "repeat") return REPEATS.includes(value) ? { ...draft, repeat: value } : draft;
  if (chip === "meetingType") {
    const type = typeOf(meetingTypes, value);
    return type ? atLeast({ ...draft, meetingType: type.id, error: null }, type.duration) : draft;
  }
  return draft;
}

// The draft moved to start at wall minute `startMin`, keeping its length.
// It no longer sits where C put it.
export function moveTo(draft, startMin) {
  return rebased({ ...draft, start: startMin, end: startMin + (draft.end - draft.start), origin: null });
}

// The params of `calendar:open_booking`.
export function toOpenPayload(draft) {
  return { draft: draft.id, meeting_type: draft.meetingType, start: formatWall(draft.start), end: formatWall(draft.end), repeat: draft.repeat };
}

// What changes when an opening is drawn on the grid: its meeting type's
// name, no calendar colour, and a class of its own. Nothing for an event.
export function openingLook(draft, meetingTypes, strings) {
  if (draft.kind !== "open") return {};
  const type = typeOf(meetingTypes, draft.meetingType);
  return { title: interpolate(strings.open_draft_title, { name: type?.name ?? "" }), colour: null, free: false, opening: true };
}

/**
 * Where C puts an opening: C's own rules (calendar/draft.js `nextSlot`),
 * with the bookable windows (`[{start, end}]`, wall times, as
 * `calendar:bookable` sends them) counting as taken, so the slot is one
 * guests cannot book yet. Busy events count too: opening over them would
 * offer nothing.
 *
 * Never a slot already past, since nothing past can be opened. A slot
 * before `now` is looked for again on today alone, from the next quarter
 * hour, when today is visible: same day, best effort, so when nothing frees
 * up before midnight C's first candidate stands. When today is not visible
 * (a week already over) there is none: null, and the draft stays where C
 * put it for the server to answer.
 */
export function nextOpenSlot(now, days, events, windows, length, floor = 0) {
  const bookable = windows.map((w) => ({ id: `bookable-${w.start}`, kind: "bookable", startMin: parseWall(w.start), endMin: parseWall(w.end), long: false, free: false }));
  const taken = [...events, ...bookable];
  const slot = nextSlot(now, days, taken, length, floor);
  if (slot.startMin >= now) return slot;
  const today = isoFromDay(Math.floor(now / MINUTES_PER_DAY));
  return days.includes(today) ? nextSlot(now, [today], taken, length, floor) : null;
}
