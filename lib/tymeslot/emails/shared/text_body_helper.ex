defmodule Tymeslot.Emails.Shared.TextBodyHelper do
  @moduledoc """
  Helper functions for generating consistent text body content in email templates.
  """

  alias Tymeslot.Emails.Shared.SharedHelpers

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Formats basic meeting details for text body.
  """
  @spec format_meeting_details(map()) :: String.t()
  def format_meeting_details(appointment_details) do
    locale = Map.get(appointment_details, :attendee_locale, "en")
    format_meeting_details(appointment_details, locale)
  end

  @spec format_meeting_details(map(), String.t()) :: String.t()
  def format_meeting_details(appointment_details, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      details = [
        "#{dgettext("emails", "Date:")} #{SharedHelpers.format_date(appointment_details.date, locale)}",
        format_time_line(appointment_details, locale),
        format_location_line(appointment_details),
        format_meeting_type_line(appointment_details.meeting_type)
      ]

      details
      |> Enum.filter(& &1)
      |> Enum.join("\n")
    end)
  end

  @doc """
  Formats video meeting section for text body.
  """
  @spec format_video_section(String.t() | nil, String.t()) :: String.t()
  def format_video_section(meeting_url, locale \\ "en")

  def format_video_section(meeting_url, locale) when is_binary(meeting_url) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      """

      #{dgettext("emails", "JOIN VIDEO MEETING:")}
      #{meeting_url}
      #{dgettext("emails", "The meeting room opens 5 minutes before your scheduled time.")}
      """
    end)
  end

  def format_video_section(_meeting_url, _locale), do: ""

  @doc """
  Formats action links for text body.
  """
  @spec format_action_links(map()) :: String.t()
  def format_action_links(appointment_details),
    do:
      format_action_links(
        appointment_details,
        Map.get(appointment_details, :attendee_locale, "en")
      )

  @spec format_action_links(map(), String.t()) :: String.t()
  def format_action_links(appointment_details, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      links = []

      links =
        if appointment_details[:reschedule_url] do
          ["#{dgettext("emails", "Reschedule:")} #{appointment_details.reschedule_url}" | links]
        else
          links
        end

      links =
        if appointment_details[:cancel_url] do
          ["#{dgettext("emails", "Cancel:")} #{appointment_details.cancel_url}" | links]
        else
          links
        end

      if Enum.empty?(links) do
        ""
      else
        """

        #{dgettext("emails", "ACTIONS:")}
        #{Enum.join(Enum.reverse(links), "\n")}
        """
      end
    end)
  end

  @doc """
  Formats attendee information for text body.
  """
  @spec format_attendee_info(map()) :: String.t()
  def format_attendee_info(appointment_details),
    do:
      format_attendee_info(
        appointment_details,
        Map.get(appointment_details, :attendee_locale, "en")
      )

  @spec format_attendee_info(map(), String.t()) :: String.t()
  def format_attendee_info(appointment_details, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      info = [
        "#{dgettext("emails", "Name:")} #{appointment_details.attendee_name}",
        "#{dgettext("emails", "Email:")} #{appointment_details.attendee_email}"
      ]

      message_section =
        if appointment_details[:attendee_message] do
          "\n\n#{dgettext("emails", "MESSAGE FROM ATTENDEE:")}\n\"#{appointment_details.attendee_message}\""
        else
          ""
        end

      """

      #{dgettext("emails", "ATTENDEE INFORMATION:")}
      #{Enum.join(info, "\n")}#{message_section}
      """
    end)
  end

  defp format_time_line(appointment_details, locale) do
    time_key =
      cond do
        appointment_details[:start_time_attendee_tz] -> :start_time_attendee_tz
        appointment_details[:start_time_owner_tz] -> :start_time_owner_tz
        appointment_details[:start_time] -> :start_time
        true -> nil
      end

    if time_key && appointment_details[:duration] do
      time_str = SharedHelpers.format_time(appointment_details[time_key], locale)
      duration_str = SharedHelpers.format_duration(appointment_details.duration, locale)
      "#{dgettext("emails", "Time:")} #{time_str} (#{duration_str})"
    end
  end

  defp format_location_line(details),
    do: "#{dgettext("emails", "Location:")} #{SharedHelpers.format_location(details)}"

  defp format_meeting_type_line(meeting_type) when is_binary(meeting_type) and meeting_type != "",
    do: "#{dgettext("emails", "Type:")} #{meeting_type}"

  defp format_meeting_type_line(_meeting_type), do: nil
end
