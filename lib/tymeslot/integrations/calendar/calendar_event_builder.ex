defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilder do
  @moduledoc """
  Builds calendar event data structures from meeting records.

  Transforms a meeting schema into the map format expected by calendar
  providers (CalDAV, Google, Outlook). Handles description assembly
  including attendee messages, custom question answers, and video meeting
  links.
  """

  alias Tymeslot.CustomFields.AnswerRenderer

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

  The attendee identity is prepended because `ICalBuilder` deliberately
  does not emit an `ATTENDEE` line on the CalDAV-write path (issue #41) —
  if the description didn't carry the attendee's name and email the
  organiser would have no way to see who the meeting is with from inside
  their calendar app.

  Custom question answers are appended directly after the attendee message
  so the organiser sees what was asked at booking time alongside the rest
  of the attendee's input, without having to open the email or dashboard.
  """
  @spec build_event_description(map()) :: String.t()
  def build_event_description(meeting) do
    parts = [
      attendee_identity_line(meeting),
      meeting.description,
      if(meeting.attendee_message, do: "\n\nMessage from attendee:\n#{meeting.attendee_message}"),
      custom_answers_section(meeting),
      if(meeting.meeting_url, do: "\n\nVideo meeting: #{meeting.meeting_url}")
    ]

    parts
    |> Enum.filter(& &1)
    |> Enum.join()
  end

  defp custom_answers_section(meeting) do
    snapshot = Map.get(meeting, :custom_fields_snapshot) || []
    answers = Map.get(meeting, :custom_field_answers) || %{}

    lines =
      for field <- snapshot,
          value = AnswerRenderer.render(field, Map.get(answers, field["id"])),
          value != "" do
        "#{field["label"]}: #{value}"
      end

    case lines do
      [] -> nil
      lines -> "\n\nAdditional details:\n" <> Enum.join(lines, "\n")
    end
  end

  defp attendee_identity_line(%{attendee_email: email} = meeting)
       when is_binary(email) and email != "" do
    case Map.get(meeting, :attendee_name) do
      name when is_binary(name) and name != "" -> "Attendee: #{name} <#{email}>\n\n"
      _missing -> "Attendee: #{email}\n\n"
    end
  end

  defp attendee_identity_line(_meeting), do: nil
end
