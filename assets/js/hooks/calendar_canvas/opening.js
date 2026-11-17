/**
 * "Open for booking" in quick create, for the CalendarCanvas hook (mixed in
 * beside the create mixin, whose popover and pushes it shares).
 *
 * The kind switch above the field (calendar/quick_create.js) turns the
 * draft into an opening for one of the organiser's meeting types
 * (`settings.meeting_types`): the field hides, and the chips become meeting
 * type, date, start and end, with "Just this once | Every week". A draft C
 * placed (`origin: "next"`) moves, once, to the next slot guests cannot book
 * yet, read from the last `calendar:bookable` windows (`this.bookable`),
 * unless the organiser changed its time first (which clears `origin`).
 * With no calendar to write events to, a new draft starts as an opening.
 *
 * Save pushes `calendar:open_booking` and settles as a create does
 * (`pushGuarded`): accepted, the popover closes and the draft stays drawn
 * until the next `calendar:bookable` arrives (`holdOpening`), which draws
 * the result, so the slot never flickers empty in between; refused, the message shows
 * on the chip the reply names; lost, the draft goes and a notice asks the
 * organiser to check their bookable times.
 */
import { applyOpening, moveTo, nextOpenSlot, toOpenPayload, withKind } from "../../calendar/opening.js";
import { periodDays } from "../../calendar/time.js";

export const OpeningMixin = {
  meetingTypes() {
    return this.settings?.meeting_types || [];
  },

  // The draft a click, a drag or C starts quick create with.
  initialDraft(draft) {
    const noCalendar = !(this.settings?.calendars || []).length;
    return noCalendar && this.meetingTypes().length ? this.kindDraft(draft, "open") : draft;
  },

  // `draft` as kind `kind`; a draft C placed, at a time the organiser has
  // not changed since, moves to a slot not yet bookable the first time it
  // becomes an opening. With no such slot (a week already past) it stays.
  kindDraft(draft, kind) {
    const next = withKind(draft, kind, this.meetingTypes());
    if (next.kind !== "open" || draft.kind === "open" || next.origin !== "next") return next;
    const range = this.nextOpenRange(next.end - next.start);
    return range ? moveTo(next, range.startMin) : { ...next, origin: null };
  },

  toKind(kind) {
    if (!this.draft || this.draft.kind === kind) return;
    this.updateDraft(this.kindDraft(this.draft, kind));
  },

  changeOpening(chip, value) {
    this.updateDraft(applyOpening(this.draft, chip, value, this.meetingTypes()));
  },

  nextOpenRange(length) {
    const days = periodDays(this.view, this.date, this.settings.week_start, this.settings.show_weekends);
    return nextOpenSlot(this.nowMinute(), days, [...this.cache.events.values()], this.bookable?.windows || [], length, this.currentScale().firstMinute);
  },

  saveOpening() {
    this.updateDraft({ ...this.draft, status: "saving", error: null });
    const { id } = this.draft;
    this.pushGuarded(
      "calendar:open_booking",
      toOpenPayload(this.draft),
      (reply) => this.openReplied(id, reply),
      () => this.createLost(id, this.strings.open_unconfirmed),
    );
  },

  openReplied(id, reply) {
    if (this.draft?.id !== id) return;
    if (reply?.accepted) {
      const returnTo = this.quick?.returnTo;
      this.closeQuickCreate();
      this.holdOpening(this.draft);
      this.restoreQuickFocus(returnTo);
      return;
    }
    this.reopenWithError(reply?.field ?? null, reply?.error || this.strings.open_refused);
  },
};
