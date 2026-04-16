defmodule Tymeslot.Integrations.Calendar.IcsGenerator do
  @moduledoc """
  Module for generating ICS (iCalendar) files for meeting appointments.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Generates an ICS file content for a meeting/appointment.

  ## Parameters
    - meeting_details: Map containing meeting information
    - locale: Locale for translated strings (default: "en")
  """
  @spec generate_ics(map(), String.t()) :: String.t()
  def generate_ics(meeting_details, locale \\ "en") do
    generate_ics_with(meeting_details, :request, nil, locale)
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
  Generates a METHOD:CANCEL ICS attachment for cancelling an existing event.

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
      content_type: content_type_for(method),
      data: ics_content
    }
  end

  defp content_type_for(:request), do: "text/calendar; charset=utf-8; method=REQUEST"
  defp content_type_for(:cancel), do: "text/calendar; charset=utf-8; method=CANCEL"

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

  defp render_vcalendar(event, method, sequence) do
    attendee_line = if event.attendee, do: "ATTENDEE:#{event.attendee}\n", else: ""
    sequence_line = if is_integer(sequence), do: "SEQUENCE:#{sequence}\n", else: ""
    status = status_for(method, event.status)

    """
    BEGIN:VCALENDAR
    VERSION:2.0
    METHOD:#{method_token(method)}
    PRODID:-//Tymeslot//Tymeslot 1.0//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:#{event.uid}
    DTSTAMP:#{format_datetime_utc(DateTime.utc_now())}
    DTSTART:#{format_datetime_utc(event.dtstart)}
    DTEND:#{format_datetime_utc(event.dtend)}
    #{sequence_line}SUMMARY:#{escape_ical_text(event.summary || dgettext("emails", "Meeting"))}
    DESCRIPTION:#{escape_ical_text(event.description)}
    LOCATION:#{escape_ical_text(event.location)}
    ORGANIZER:#{event.organizer}
    #{attendee_line}STATUS:#{status}
    END:VEVENT
    END:VCALENDAR
    """
  end

  defp method_token(:request), do: "REQUEST"
  defp method_token(:cancel), do: "CANCEL"

  defp status_for(:cancel, _status), do: "CANCELLED"
  defp status_for(:request, status), do: status

  defp format_organizer(meeting_details) do
    organizer_name = Map.get(meeting_details, :organizer_name)

    organizer_email =
      Map.get(
        meeting_details,
        :organizer_email,
        Application.get_env(:tymeslot, :email)[:from_email]
      )

    case organizer_name do
      name when is_binary(name) and name != "" ->
        quoted_name = String.replace(name, "\"", "'")
        "CN=\"#{quoted_name}\":mailto:#{organizer_email}"

      _other ->
        "mailto:#{organizer_email}"
    end
  end

  defp format_attendees(meeting_details) do
    attendee_email = Map.get(meeting_details, :attendee_email)

    case attendee_email do
      email when is_binary(email) and email != "" ->
        attendee_name = Map.get(meeting_details, :attendee_name)

        case attendee_name do
          name when is_binary(name) and name != "" ->
            quoted_name = String.replace(name, "\"", "'")
            "CN=\"#{quoted_name}\":mailto:#{email}"

          _other ->
            "mailto:#{email}"
        end

      _other ->
        nil
    end
  end

  defp build_ics_description(meeting_details) do
    parts = [
      Map.get(meeting_details, :description),
      build_attendee_message_section(meeting_details),
      build_video_url_section(meeting_details)
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
