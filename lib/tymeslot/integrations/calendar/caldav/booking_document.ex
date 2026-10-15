defmodule Tymeslot.Integrations.Calendar.CalDAV.BookingDocument do
  @moduledoc """
  Points a booking's update at the iCalendar document the organiser's CalDAV
  server last gave us, so the write patches that document instead of
  rebuilding the event from Tymeslot's payload.

  A booking update (a reschedule, a video room attached, an approval) carries
  the whole booking as `CalendarEventBuilder` models it. Rebuilt from that
  payload, the event loses everything the organiser or their calendar client
  added to it: `CATEGORIES`, `X-` properties, extra `ATTENDEE`s and their
  `PARTSTAT`, their own alarms. `CalDAV.Events.update_calendar_event/5`
  patches instead whenever the payload carries `:raw_ical`, so this module
  supplies it from the cached `provider_calendar_events` row, with the ETag it
  came with and the href the event lives at.

  ## What the patch still writes

  Every property the booking payload names: `DTSTART`, `DTEND`, `SUMMARY`,
  `DESCRIPTION`, `LOCATION`, `CONFERENCE`, `STATUS` and `TRANSP`. An edit the
  organiser made to one of those in their own client is overwritten, as it
  always was; Tymeslot owns them.

  Not written: the attendee block, since the booking payload names the
  attendee by `:attendee_email` rather than the `:attendees` list the patcher
  merges, and the alarms (see `keep_stored_alarms`). Neither is something a
  booking update can change: a meeting's attendee and its reminders are both
  fixed when it is booked, and the create wrote them to the event already.
  `ATTACH` and `ORGANIZER` are kept for the same reason.

  ## When nothing is supplied

  Only a CalDAV-family write of a meeting's own event is pointed at the cache.
  Google and Outlook never receive the document, and a meeting with no
  calendar integration, or no cached row for this event in that integration,
  or a row with no document, is rebuilt from the payload as before.

  The cached row is looked up in the meeting's integration, which is the one
  `ClientManager.resolve_client/1` writes through for a meeting, and by the
  very UID being written, so a row of another integration or another event
  can never be patched onto this one.
  """

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Meetings.MeetingSchema

  @doc """
  Returns `{:ok, event_data}` carrying the cached document for a CalDAV
  update of `meeting`'s event `uid`, or `:none` when the write should go out
  as given.

  The returned payload sets `keep_stored_alarms: true`: the document's
  `VALARM`s are the organiser's to keep, and `CalDAV.Events` leaves them as
  stored when it patches, while a rebuild still writes the payload's
  `:reminders`.
  """
  @spec for_update(map(), String.t(), map(), term()) :: {:ok, map()} | :none
  def for_update(
        %{provider_type: provider},
        uid,
        event_data,
        %MeetingSchema{calendar_integration_id: integration_id}
      )
      when is_integer(integration_id) and is_binary(uid) do
    with true <- ProviderConfig.caldav_based?(provider),
         false <- Map.has_key?(event_data, :raw_ical),
         {:ok, %{raw_ical: raw_ical} = cached} when is_binary(raw_ical) and raw_ical != "" <-
           ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:ok,
       Map.merge(event_data, %{
         raw_ical: raw_ical,
         etag: cached.etag,
         provider_event_id: cached.provider_event_id,
         keep_stored_alarms: true
       })}
    else
      _no_document -> :none
    end
  end

  def for_update(_client, _uid, _event_data, _context), do: :none
end
