defmodule Tymeslot.Meetings.ExternalCalendar do
  @moduledoc """
  The meeting side of reconciling bookings with the host's external calendar:
  applying changes a sync pass detects on a booking's provider event, finding
  the meeting a calendar event belongs to, matching meetings and cached
  provider events by their calendar-event identifiers, and folding bookings
  into busy periods.

  The public entry point for the calendar integrations and the calendar grid;
  the work lives in `Tymeslot.Meetings.ExternalCalendarChanges`,
  `Tymeslot.Meetings.CalendarEventLink`,
  `Tymeslot.Meetings.MeetingCalendarQueries` and
  `Tymeslot.Meetings.BusyPeriods`.
  """

  alias Tymeslot.Meetings.{
    BusyPeriods,
    CalendarEventLink,
    ExternalCalendarChanges,
    MeetingCalendarQueries
  }

  @doc """
  Applies an externally detected calendar change (`:deleted` or `:modified`)
  to the meeting linked to the given provider event, if any.

  This is the entry point the Calendar context uses when a sync worker
  detects that a provider event linked to a meeting changed externally.
  Owns all meeting-side consequences: sync-status updates, auto-cancellation
  on external deletion, and host notifications.

  `snapshot_at:` is when the read that saw the change began; see
  `Tymeslot.Meetings.ExternalCalendarChanges.apply_change/5`.
  """
  defdelegate apply_external_calendar_change(
                calendar_integration_id,
                provider_event_id,
                uid,
                signal,
                opts \\ []
              ),
              to: ExternalCalendarChanges,
              as: :apply_change

  @doc """
  Applies an external calendar change signal to a meeting already in hand.

  The identifier-free counterpart of `apply_external_calendar_change/5`, for
  callers that resolved the meeting themselves, such as a batch that matched many
  events in one query rather than two lookups per event.
  """
  defdelegate apply_external_calendar_change_to_meeting(meeting, signal),
    to: ExternalCalendarChanges,
    as: :apply_change_to_meeting

  @doc """
  Moves a meeting's end to the one the host gave its provider event, when the
  host lengthened or shortened it without moving its start.
  """
  defdelegate apply_external_end_change(meeting, end_time),
    to: ExternalCalendarChanges,
    as: :apply_end_change

  @doc """
  Records the end the host's calendar event shows for a meeting found in step
  with it, as the end a later end change is measured against.
  """
  defdelegate record_seen_calendar_end(meeting, end_time), to: ExternalCalendarChanges

  @doc """
  Clears an `"externally_modified"` flag once a sync pass finds the provider event agreeing
  again; detection is stateless, so only such a pass can retire the flag.
  """
  defdelegate resolve_external_calendar_change(meeting),
    to: ExternalCalendarChanges,
    as: :resolve_modification

  @doc """
  Looks up a meeting linked to a calendar event by provider event ID or UID.

  Returns `{:ok, meeting}` or `{:error, :not_found}`. Tries
  `provider_event_id` first, falls back to `uid`.
  """
  defdelegate find_meeting_by_calendar_event(calendar_integration_id, provider_event_id, uid),
    to: ExternalCalendarChanges,
    as: :find_linked_meeting

  @doc """
  Returns the meetings linked to the given integration that share any of `identifiers`,
  keyed by every identifier each carries (`drawn_for: user_id`: that organiser's drawn ones).
  """
  defdelegate list_meetings_by_calendar_identifiers(
                calendar_integration_id,
                identifiers,
                opts \\ []
              ),
              to: MeetingCalendarQueries,
              as: :list_by_calendar_identifiers

  @doc """
  `find_meeting_by_calendar_event/3` for many events in one query: the
  `{calendar_integration_id, provider_event_id, calendar_uid}` of every
  meeting on `integration_ids` matching one of the provider event ids or uids.
  """
  defdelegate list_calendar_links(integration_ids, provider_event_ids, uids),
    to: MeetingCalendarQueries

  @doc """
  Returns the subset of `identifiers` carried by any meeting the organiser
  `organizer_user_id` organises, in any status and through any integration.
  """
  defdelegate organizer_calendar_identifiers(organizer_user_id, identifiers),
    to: MeetingCalendarQueries

  @doc """
  Returns the non-blank identifiers by which `record` — a meeting or a cached
  provider calendar event — is matched to its counterpart on the other side.
  """
  defdelegate calendar_event_identifiers(record), to: CalendarEventLink, as: :identifiers

  @doc """
  Collects every calendar-event identifier across `records` into one set, for
  matching many records against many.
  """
  defdelegate calendar_identifier_set(records), to: CalendarEventLink, as: :identifier_set

  @doc """
  Whether `record` shares a calendar-event identifier with `identifier_set`,
  i.e. whether a meeting and a cached provider event describe the same event.
  """
  defdelegate linked_to_calendar_event?(record, identifier_set),
    to: CalendarEventLink,
    as: :linked?

  @doc """
  Drops from `records` every calendar event that mirrors `meeting`, so a
  meeting's own provider event never counts as a conflict with itself. `nil`
  leaves `records` untouched.
  """
  defdelegate reject_calendar_event_mirrors(records, meeting),
    to: CalendarEventLink,
    as: :reject_mirrors

  @doc """
  Merges the organiser's live bookings in `[from, to)` into `calendar_events`
  as busy periods, so a booking blocks its own slot whether or not it has
  reached the host's calendar. See `Tymeslot.Meetings.BusyPeriods`.
  """
  defdelegate merge_busy_periods(calendar_events, organizer_user_id, from, to),
    to: BusyPeriods,
    as: :merge
end
