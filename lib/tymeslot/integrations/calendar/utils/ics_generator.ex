defmodule Tymeslot.Integrations.Calendar.IcsGenerator do
  @moduledoc """
  Module for generating ICS (iCalendar) files for meeting appointments.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer

  @doc """
  Generates an ICS file content for a meeting/appointment.

  ## Parameters
    - meeting_details: Map containing meeting information
    - locale: Locale for translated strings (default: "en")
  """
  @spec generate_ics(map(), String.t()) :: String.t()
  def generate_ics(meeting_details, locale \\ "en") do
    generate_ics_with(meeting_details, :none, nil, locale)
  end

  @doc """
  Generates a Swoosh email attachment with ICS content.
  """
  @spec generate_ics_attachment(map(), String.t(), String.t()) :: Swoosh.Attachment.t()
  def generate_ics_attachment(meeting_details, locale \\ "en", filename \\ "meeting.ics") do
    build_attachment(meeting_details, :request, nil, locale, filename)
  end

  @doc """
  Generates an ICS attachment for an event update with the given SEQUENCE number.
  SEQUENCE > 0 signals to calendar clients that this is an update to an existing event.
  """
  @spec generate_ics_update_attachment(map(), non_neg_integer(), String.t(), String.t()) ::
          Swoosh.Attachment.t()
  def generate_ics_update_attachment(
        meeting_details,
        sequence,
        locale \\ "en",
        filename \\ "meeting.ics"
      ) do
    build_attachment(meeting_details, :request, sequence, locale, filename)
  end

  @doc """
  Generates an ICS attachment that cancels an existing event
  (`METHOD:PUBLISH` + `STATUS:CANCELLED`). We deliberately avoid
  `METHOD:CANCEL` here — see the note on `render_vcalendar/3`.

  The `sequence` should be the next value after the last sent invitation so
  calendar clients recognise the cancellation as more recent than the event
  they already have on file.
  """
  @spec generate_ics_cancel_attachment(map(), non_neg_integer(), String.t(), String.t()) ::
          Swoosh.Attachment.t()
  def generate_ics_cancel_attachment(
        meeting_details,
        sequence,
        locale \\ "en",
        filename \\ "meeting.ics"
      ) do
    build_attachment(meeting_details, :cancel, sequence, locale, filename)
  end

  defp build_attachment(meeting_details, method, sequence, locale, filename) do
    ics_content = generate_ics_with(meeting_details, method, sequence, locale)

    %Swoosh.Attachment{
      filename: filename,
      content_type: "text/calendar; charset=utf-8; method=PUBLISH",
      data: ics_content
    }
  end

  defp generate_ics_with(meeting_details, method, sequence, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      meeting_details
      |> build_event()
      |> render_vcalendar(method, sequence)
    end)
  end

  defp build_event(meeting_details) do
    %{
      summary: Map.get(meeting_details, :title, dgettext("emails", "Meeting")),
      description: build_ics_description(meeting_details),
      dtstart: meeting_details.start_time,
      dtend: meeting_details.end_time,
      location: determine_location(meeting_details),
      uid:
        "#{Map.get(meeting_details, :uid, UUID.uuid4())}@#{Application.get_env(:tymeslot, :email)[:domain]}",
      organizer: format_organizer(meeting_details),
      attendee: format_attendees(meeting_details),
      status: "CONFIRMED"
    }
  end

  # Tymeslot emails always advertise METHOD:PUBLISH (not REQUEST/CANCEL). The
  # organiser's calendar is already updated via the CalDAV/OAuth write path and
  # attendee RSVP is handled by booking URLs in the email body — iTIP on the
  # wire would cause recipient-side mail servers (Zimbra, Nextcloud/Sabre,
  # Apple iCloud Mail) to auto-import the attachment and emit extra
  # notifications. See issue #41.
  #
  # `SCHEDULE-AGENT=CLIENT` on ORGANIZER/ATTENDEE is defence-in-depth per
  # RFC 6638 §7.1 for the same reason.
  defp render_vcalendar(event, method, sequence) do
    attendee_line = if event.attendee, do: "ATTENDEE;#{event.attendee}\n", else: ""
    sequence_line = if is_integer(sequence), do: "SEQUENCE:#{sequence}\n", else: ""
    method_line = if method == :none, do: "", else: "METHOD:PUBLISH\n"
    status = status_for(method, event.status)

    fold_lines("""
    BEGIN:VCALENDAR
    VERSION:2.0
    #{method_line}PRODID:-//Tymeslot//Tymeslot 1.0//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:#{event.uid}
    DTSTAMP:#{format_datetime_utc(DateTime.utc_now())}
    DTSTART:#{format_datetime_utc(event.dtstart)}
    DTEND:#{format_datetime_utc(event.dtend)}
    #{sequence_line}SUMMARY:#{escape_ical_text(event.summary || dgettext("emails", "Meeting"))}
    DESCRIPTION:#{escape_ical_text(event.description)}
    LOCATION:#{escape_ical_text(event.location)}
    ORGANIZER;#{event.organizer}
    #{attendee_line}STATUS:#{status}
    END:VEVENT
    END:VCALENDAR
    """)
  end

  # RFC 5545 §3.1 — content lines must not exceed 75 octets (excluding line
  # terminator). Fold by inserting CRLF + a single SPACE continuation marker.
  # First segment may be up to 75 octets; each continuation segment up to 74
  # octets (the leading SPACE occupies one octet of the 75-octet allowance).
  # We split at UTF-8 character boundaries so multi-byte codepoints are never
  # torn in half.
  defp fold_lines(ical_string) do
    ical_string
    |> String.split("\n")
    |> Enum.map_join("\n", &fold_line/1)
  end

  defp fold_line(line) do
    fold_line_acc(line, _first = true, _acc = [])
  end

  defp fold_line_acc(<<>>, _first, acc), do: acc |> Enum.reverse() |> Enum.join("\r\n ")

  defp fold_line_acc(rest, first, acc) do
    limit = if first, do: 75, else: 74

    {chunk, remaining} = take_octets(rest, limit)
    fold_line_acc(remaining, false, [chunk | acc])
  end

  # Takes up to `max_bytes` octets from `binary`, never splitting a UTF-8
  # multi-byte codepoint. Returns `{taken, rest}`.
  defp take_octets(binary, max_bytes) when byte_size(binary) <= max_bytes do
    {binary, ""}
  end

  defp take_octets(binary, max_bytes) do
    # Walk forward from max_bytes to find a UTF-8 codepoint boundary.
    split_at = safe_utf8_split(binary, max_bytes)
    <<chunk::binary-size(^split_at), rest::binary>> = binary
    {chunk, rest}
  end

  # Returns the largest byte offset ≤ `pos` at which `binary` can be split
  # without tearing a UTF-8 multi-byte sequence. UTF-8 continuation bytes
  # have the bit pattern 10xxxxxx (0x80–0xBF); back up past them to land on
  # a leading byte.
  defp safe_utf8_split(binary, pos) do
    pos = min(pos, byte_size(binary))
    retreat_to_boundary(binary, pos)
  end

  defp retreat_to_boundary(_binary, 0), do: 0

  defp retreat_to_boundary(binary, pos) do
    byte = :binary.at(binary, pos - 1)

    if continuation_byte?(byte) do
      retreat_to_boundary(binary, pos - 1)
    else
      pos
    end
  end

  # UTF-8 continuation bytes: 10xxxxxx
  defp continuation_byte?(byte), do: byte >= 0x80 and byte <= 0xBF

  defp status_for(:cancel, _status), do: "CANCELLED"
  defp status_for(_method, status), do: status

  defp format_organizer(meeting_details) do
    organizer_name = Map.get(meeting_details, :organizer_name)

    organizer_email =
      Map.get(
        meeting_details,
        :organizer_email,
        Application.get_env(:tymeslot, :email)[:from_email]
      )

    "SCHEDULE-AGENT=CLIENT#{cn_param(organizer_name)}:mailto:#{organizer_email}"
  end

  defp format_attendees(meeting_details) do
    attendee_email = Map.get(meeting_details, :attendee_email)

    case attendee_email do
      email when is_binary(email) and email != "" ->
        attendee_name = Map.get(meeting_details, :attendee_name)
        "SCHEDULE-AGENT=CLIENT#{cn_param(attendee_name)}:mailto:#{email}"

      _other ->
        nil
    end
  end

  defp cn_param(name) when is_binary(name) and name != "" do
    quoted_name =
      name
      |> String.replace(~r/[\r\n]/, " ")
      |> String.replace("\"", "'")

    ";CN=\"#{quoted_name}\""
  end

  defp cn_param(_other), do: ""

  defp build_ics_description(meeting_details) do
    parts = [
      Map.get(meeting_details, :description),
      build_attendee_message_section(meeting_details),
      build_video_url_section(meeting_details),
      build_custom_answers_section(meeting_details)
    ]

    parts
    |> Enum.filter(&(&1 && String.trim(&1) != ""))
    |> Enum.join("\n\n")
  end

  defp build_attendee_message_section(meeting_details) do
    case Map.get(meeting_details, :attendee_message) do
      message when is_binary(message) and message != "" ->
        attendee_label = Map.get(meeting_details, :attendee_name, dgettext("emails", "attendee"))

        "#{dgettext("emails", "Message from %{name}:", name: attendee_label)}\n#{String.trim(message)}"

      _other ->
        nil
    end
  end

  defp build_video_url_section(meeting_details) do
    case Map.get(meeting_details, :meeting_url) do
      url when is_binary(url) and url != "" ->
        "#{dgettext("emails", "Video meeting:")} #{url}"

      _other ->
        nil
    end
  end

  defp determine_location(meeting_details) do
    meeting_url = Map.get(meeting_details, :meeting_url)
    location = Map.get(meeting_details, :location)

    cond do
      is_binary(meeting_url) and meeting_url != "" ->
        dgettext("emails", "Video Call")

      is_binary(location) and location != "" ->
        location

      true ->
        ""
    end
  end

  defp build_custom_answers_section(meeting_details) do
    snap = Map.get(meeting_details, :custom_fields_snapshot)
    ans = Map.get(meeting_details, :custom_field_answers, %{})

    case snap do
      list when is_list(list) and list != [] ->
        Enum.map_join(list, "\n", fn d ->
          label = d["label"]
          value = AnswerRenderer.render(d, Map.get(ans || %{}, d["id"]))
          "#{label}: #{value}"
        end)

      _other ->
        nil
    end
  end

  defp escape_ical_text(text) when is_binary(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace(";", "\\;")
    |> String.replace(",", "\\,")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "")
  end

  defp escape_ical_text(nil), do: ""

  defp format_datetime_utc(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
