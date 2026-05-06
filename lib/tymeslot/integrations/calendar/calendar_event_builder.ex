defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilder do
  @moduledoc """
  Builds calendar event data structures from meeting records.

  Transforms a meeting schema into the map format expected by calendar
  providers (CalDAV, Google, Outlook). Handles description assembly
  including attendee messages and video meeting links.
  """

  @doc """
  Builds a calendar event data map from a meeting record.

  Returns a map with `:uid`, `:summary`, `:description`, `:start_time`,
  `:end_time`, `:timezone`, `:location`, `:organizer_name`,
  `:organizer_email`, `:attendee_name`, and `:attendee_email` keys.

  The organiser fields are emitted so `ICalBuilder` can tag the resulting
  `ORGANIZER` line with `SCHEDULE-AGENT=CLIENT` (RFC 6638 §7.1) — without
  them, scheduling-aware CalDAV servers (Zimbra, Nextcloud/Sabre, Apple
  iCloud) inject their own ORGANIZER and fire the iTIP pipeline, which
  duplicates the invitation email Tymeslot already sends.
  """
  @spec build_event_data(map()) :: map()
  def build_event_data(meeting) do
    %{
      uid: meeting.uid,
      summary: meeting.title,
      description: build_event_description(meeting),
      start_time: meeting.start_time,
      end_time: meeting.end_time,
      timezone: meeting.attendee_timezone,
      location: meeting.meeting_url || meeting.location,
      organizer_name: meeting.organizer_name,
      organizer_email: meeting.organizer_email,
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email
    }
  end

  @doc """
  Assembles a calendar event description from a meeting's fields.

  Concatenates the meeting description, attendee message (if present),
  and video meeting URL (if present).
  """
  @spec build_event_description(map()) :: String.t()
  def build_event_description(meeting) do
    parts = [
      meeting.description,
      if(meeting.attendee_message, do: "\n\nMessage from attendee:\n#{meeting.attendee_message}"),
      if(meeting.meeting_url, do: "\n\nVideo meeting: #{meeting.meeting_url}")
    ]

    parts
    |> Enum.filter(& &1)
    |> Enum.join()
  end
end
