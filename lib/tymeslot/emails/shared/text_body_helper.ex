defmodule Tymeslot.Emails.Shared.TextBodyHelper do
  @moduledoc """
  Helper functions for generating consistent text body content in email templates.
  """

  alias Tymeslot.Emails.Shared.SharedHelpers

  @doc """
  Formats basic meeting details for text body.
  """
  @spec format_meeting_details(map()) :: String.t()
  def format_meeting_details(appointment_details) do
    details = [
      "Date: #{SharedHelpers.format_date(appointment_details.date)}",
      format_time_line(appointment_details),
      format_location_line(appointment_details.location),
      format_meeting_type_line(appointment_details.meeting_type)
    ]

    details
    |> Enum.filter(& &1)
    |> Enum.join("\n")
  end

  @doc """
  Formats video meeting section for text body.
  """
  @spec format_video_section(String.t() | nil) :: String.t()
  def format_video_section(meeting_url) when is_binary(meeting_url) do
    """

    JOIN VIDEO MEETING:
    #{meeting_url}
    The meeting room opens 5 minutes before your scheduled time.
    """
  end

  def format_video_section(_), do: ""

  @doc """
  Formats action links for text body.
  """
  @spec format_action_links(map()) :: String.t()
  def format_action_links(appointment_details) do
    links = []

    links =
      if appointment_details[:reschedule_url] do
        ["Reschedule: #{appointment_details.reschedule_url}" | links]
      else
        links
      end

    links =
      if appointment_details[:cancel_url] do
        ["Cancel: #{appointment_details.cancel_url}" | links]
      else
        links
      end

    if Enum.empty?(links) do
      ""
    else
      """

      ACTIONS:
      #{Enum.join(Enum.reverse(links), "\n")}
      """
    end
  end

  @doc """
  Formats attendee information for text body.
  """
  @spec format_attendee_info(map()) :: String.t()
  def format_attendee_info(appointment_details) do
    info = [
      "Name: #{appointment_details.attendee_name}",
      "Email: #{appointment_details.attendee_email}"
    ]

    message_section =
      if appointment_details[:attendee_message] do
        "\n\nMESSAGE FROM ATTENDEE:\n\"#{appointment_details.attendee_message}\""
      else
        ""
      end

    """

    ATTENDEE INFORMATION:
    #{Enum.join(info, "\n")}#{message_section}
    """
  end

  defp format_time_line(appointment_details) do
    cond do
      appointment_details[:start_time_attendee_tz] && appointment_details[:duration] ->
        "Time: #{SharedHelpers.format_time(appointment_details.start_time_attendee_tz)} (#{appointment_details.duration} minutes)"

      appointment_details[:start_time_owner_tz] && appointment_details[:duration] ->
        "Time: #{SharedHelpers.format_time(appointment_details.start_time_owner_tz)} (#{appointment_details.duration} minutes)"

      appointment_details[:start_time] && appointment_details[:duration] ->
        "Time: #{SharedHelpers.format_time(appointment_details.start_time)} (#{appointment_details.duration} minutes)"

      true ->
        nil
    end
  end

  defp format_location_line(location) when is_binary(location) and location != "",
    do: "Location: #{location}"

  defp format_location_line(_), do: nil

  defp format_meeting_type_line(meeting_type) when is_binary(meeting_type) and meeting_type != "",
    do: "Type: #{meeting_type}"

  defp format_meeting_type_line(_), do: nil
end
