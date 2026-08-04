defmodule Tymeslot.Integrations.Calendar.CalendarEventBuilder do
  @moduledoc """
  Builds calendar event data structures from meeting records.

  Transforms a meeting schema into the map format expected by calendar
  providers (CalDAV, Google, Outlook). Handles description assembly
  including attendee messages, custom question answers, and video meeting
  links.
  """

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Utils.MapKeys
  alias Tymeslot.Utils.ReminderUtils
  alias TymeslotWeb.Endpoint

  # Tymeslot's own reminder pipeline sends the reminder emails, so alarms
  # written out to a provider are always `:popup`. An EMAIL alarm would make
  # the calendar server send its own copy on top of the one Tymeslot already
  # schedules, so the attendee would be reminded twice.
  @alarm_method :popup

  @doc """
  Builds a calendar event data map from a meeting record.

  Returns a map with `:uid`, `:summary`, `:description`, `:start_time`,
  `:end_time`, `:timezone`, `:location`, `:organizer_name`,
  `:organizer_email`, `:attendee_name`, `:attendee_email`, and `:reminders`
  keys.

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
      conference_url: meeting.meeting_url,
      transparency: if(Map.get(meeting, :show_as_free), do: :transparent, else: :opaque),
      attachments: build_attachments(meeting),
      organizer_name: meeting.organizer_name,
      organizer_email: meeting.organizer_email,
      attendee_name: meeting.attendee_name,
      attendee_email: meeting.attendee_email,
      reminders: build_reminders(meeting)
    }
  end

  # The meeting stores the reminders chosen at booking time as `%{value:,
  # unit:}` (e.g. 30 "minutes" before). The provider adapters — `ICalBuilder`'s
  # VALARM writer, Google's `EventMapper`, Outlook's Graph mapping — all
  # consume `Tymeslot.Integrations.Calendar.Reminder`'s canonical
  # `%{method:, minutes_before:}` shape instead, so the two are reconciled
  # here. Reminders round-tripped through a JSONB column come back
  # string-keyed; `ReminderUtils.normalize_reminder/1` accepts either form and
  # rejects anything it can't read, which is dropped rather than written out
  # as a malformed alarm.
  defp build_reminders(meeting) do
    meeting
    |> Map.get(:reminders)
    |> List.wrap()
    |> Enum.flat_map(&to_alarm/1)
  end

  defp to_alarm(reminder) do
    case ReminderUtils.normalize_reminder(reminder) do
      {:ok, %{value: value, unit: unit}} ->
        minutes_before = div(ReminderUtils.reminder_interval_seconds(value, unit), 60)
        [%{method: @alarm_method, minutes_before: minutes_before}]

      {:error, :invalid_reminder} ->
        []
    end
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
      attachments_section(meeting),
      if(meeting.meeting_url, do: "\n\nVideo meeting: #{meeting.meeting_url}")
    ]

    parts
    |> Enum.filter(& &1)
    |> Enum.join()
  end

  @doc """
  Builds the canonical attachment list (`%{filename, url, content_type}`) from a
  meeting's `attachments_snapshot`. Absolute download URLs are derived from the
  endpoint host so calendar clients can fetch the files.
  """
  @spec build_attachments(map()) :: [map()]
  def build_attachments(meeting) do
    meeting
    |> Map.get(:attachments_snapshot)
    |> List.wrap()
    |> Enum.map(fn a ->
      %{
        filename: MapKeys.get(a, :filename),
        url: attachment_url(MapKeys.get(a, :stored_path)),
        content_type: MapKeys.get(a, :content_type)
      }
    end)
    |> Enum.reject(&is_nil(&1.url))
  end

  defp attachment_url(nil), do: nil
  defp attachment_url(path), do: Endpoint.url() <> "/uploads/" <> path

  # A plain-text "Attachments" block of download links. This is the universal
  # fallback that renders in every calendar client and provider (CalDAV, Google
  # description, Outlook body); CalDAV additionally gets native ATTACH lines.
  defp attachments_section(meeting) do
    case build_attachments(meeting) do
      [] ->
        nil

      attachments ->
        links = Enum.map_join(attachments, "\n", &"#{&1.filename}: #{&1.url}")
        "\n\nAttachments:\n#{links}"
    end
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
