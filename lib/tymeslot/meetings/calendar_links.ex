defmodule Tymeslot.Meetings.CalendarLinks do
  @moduledoc """
  How meetings are matched to provider calendar events: the lookups calendar
  sync, the calendar grid and the agenda use to tell which cached provider
  event mirrors which meeting, and to fold the organiser's own bookings into
  the busy periods the availability engine weighs.

  A thin facade over `Tymeslot.Meetings.ExternalCalendarChanges`,
  `Tymeslot.Meetings.MeetingCalendarQueries`,
  `Tymeslot.Meetings.CalendarEventLink` and `Tymeslot.Meetings.BusyPeriods`.
  """

  alias Tymeslot.Meetings.{
    BusyPeriods,
    CalendarEventLink,
    ExternalCalendarChanges,
    MeetingCalendarQueries
  }

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
