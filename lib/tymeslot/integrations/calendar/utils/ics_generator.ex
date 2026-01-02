defmodule Tymeslot.Integrations.Calendar.IcsGenerator do
  @moduledoc """
  Module for generating ICS (iCalendar) files for meeting appointments.
  """

  require Logger

  @doc """
  Generates an ICS file content for a meeting/appointment.

  ## Parameters
    - meeting_details: Map containing meeting information

  ## Expected fields in meeting_details:
    - title: Meeting title/summary
    - description: Meeting description (optional)
    - attendee_message: Message from attendee (optional)
    - meeting_url: Video meeting URL (optional)
    - start_time: DateTime for meeting start
    - end_time: DateTime for meeting end
    - location: Meeting location (optional)
    - uid: Unique identifier for the event
    - organizer_email: Organizer's email
    - organizer_name: Organizer's name (optional)
    - attendee_email: Attendee's email (optional)
    - attendee_name: Attendee's name (optional)
  """
  @spec generate_ics(map()) :: String.t()
  @dialyzer {:nowarn_function, generate_ics: 1}
  def generate_ics(meeting_details) do
    event = %Magical.Event{
      summary: Map.get(meeting_details, :title, "Meeting"),
      description: build_ics_description(meeting_details),
      dtstart: meeting_details.start_time,
      dtend: meeting_details.end_time,
      location: determine_location(meeting_details),
      uid: "#{Map.get(meeting_details, :uid, UUID.uuid4())}@#{Application.get_env(:tymeslot, :email)[:domain]}",
      organizer: format_organizer(meeting_details),
      attendee: format_attendees(meeting_details),
      status: "CONFIRMED"
    }

    calendar = %Magical.Calendar{events: [event]}

    try do
      Magical.to_ics(calendar)
    rescue
      error ->
        Logger.error("Failed to generate ICS with Magical library", error: inspect(error))
        # Fallback to basic ICS generation
        generate_basic_ics(event)
    end
  end

  @doc """
  Generates a Swoosh email attachment with ICS content.
  """
  @spec generate_ics_attachment(map(), String.t()) :: Swoosh.Attachment.t()
  def generate_ics_attachment(meeting_details, filename \\ "meeting.ics") do
    ics_content = generate_ics(meeting_details)

    %Swoosh.Attachment{
      filename: filename,
      content_type: "text/calendar; charset=utf-8; method=REQUEST",
      data: ics_content
    }
  end

  defp format_organizer(meeting_details) do
    organizer_name = Map.get(meeting_details, :organizer_name)
    organizer_email = Map.get(meeting_details, :organizer_email, Application.get_env(:tymeslot, :email)[:from_email])

    case organizer_name do
      name when is_binary(name) and name != "" ->
        "CN=#{name}:mailto:#{organizer_email}"

      _ ->
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
            "CN=#{name}:mailto:#{email}"

          _ ->
            "mailto:#{email}"
        end

      _ ->
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
        "Message from #{Map.get(meeting_details, :attendee_name, "attendee")}:\n#{String.trim(message)}"

      _ ->
        nil
    end
  end

  defp build_video_url_section(meeting_details) do
    case Map.get(meeting_details, :meeting_url) do
      url when is_binary(url) and url != "" ->
        "Video meeting: #{url}"

      _ ->
        nil
    end
  end

  defp determine_location(meeting_details) do
    cond do
      Map.get(meeting_details, :meeting_url) ->
        "Video Call"

      Map.get(meeting_details, :location) ->
        Map.get(meeting_details, :location)

      true ->
        ""
    end
  end

  defp generate_basic_ics(event) do
    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Tymeslot//Tymeslot 1.0//EN
    CALSCALE:GREGORIAN
    BEGIN:VEVENT
    UID:#{event.uid}
    DTSTAMP:#{format_datetime_utc(DateTime.utc_now())}
    DTSTART:#{format_datetime_utc(event.dtstart)}
    DTEND:#{format_datetime_utc(event.dtend)}
    SUMMARY:#{event.summary || "Meeting"}
    DESCRIPTION:#{escape_ical_text(event.description)}
    LOCATION:#{escape_ical_text(event.location)}
    ORGANIZER:#{event.organizer}
    #{if event.attendee, do: "ATTENDEE:#{event.attendee}", else: ""}
    STATUS:#{event.status}
    END:VEVENT
    END:VCALENDAR
    """
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
    |> DateTime.to_iso8601()
    |> String.replace(~r/[-:]/, "")
    |> String.replace("T", "T")
    |> String.replace("Z", "Z")
  end
end
