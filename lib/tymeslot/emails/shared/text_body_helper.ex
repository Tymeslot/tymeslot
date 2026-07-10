defmodule Tymeslot.Emails.Shared.TextBodyHelper do
  @moduledoc """
  Helper functions for generating consistent text body content in email templates.
  """

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Emails.Shared.Formatting

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
        "#{dgettext("emails", "Date:")} #{Formatting.format_date(appointment_details.date, locale)}",
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
  @spec format_action_links(Tymeslot.Emails.EmailService.appointment_details()) :: String.t()
  def format_action_links(appointment_details),
    do:
      format_action_links(
        appointment_details,
        Map.get(appointment_details, :attendee_locale, "en")
      )

  @spec format_action_links(Tymeslot.Emails.EmailService.appointment_details(), String.t()) ::
          String.t()
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
  @spec format_attendee_info(Tymeslot.Emails.EmailService.appointment_details()) :: String.t()
  def format_attendee_info(appointment_details),
    do:
      format_attendee_info(
        appointment_details,
        Map.get(appointment_details, :attendee_locale, "en")
      )

  @spec format_attendee_info(Tymeslot.Emails.EmailService.appointment_details(), String.t()) ::
          String.t()
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

  @doc """
  Formats the snapshotted custom-field answers as a plain-text section for
  email bodies. Mirrors the HTML `MeetingComponents.custom_answers_section/1`.
  Returns an empty string when there are no fields, or when every field
  renders as an empty value.
  """
  @spec format_custom_answers(map()) :: String.t()
  def format_custom_answers(appointment_details),
    do:
      format_custom_answers(
        appointment_details,
        Map.get(appointment_details, :attendee_locale, "en")
      )

  @spec format_custom_answers(map(), String.t()) :: String.t()
  def format_custom_answers(appointment_details, locale) do
    snapshot = Map.get(appointment_details, :custom_fields_snapshot) || []
    answers = Map.get(appointment_details, :custom_field_answers) || %{}

    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      rendered =
        snapshot
        |> Enum.map(fn field ->
          value = AnswerRenderer.render(field, answers[field["id"]])
          {field["label"] || "", value}
        end)
        |> Enum.reject(fn {_label, value} -> value == "" end)

      case rendered do
        [] ->
          ""

        rows ->
          lines = Enum.map_join(rows, "\n", fn {label, value} -> "#{label}: #{value}" end)

          """

          #{dgettext("emails", "ADDITIONAL DETAILS:")}
          #{lines}
          """
      end
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
      time_str = Formatting.format_time(appointment_details[time_key], locale)
      duration_str = Formatting.format_duration(appointment_details.duration, locale)
      "#{dgettext("emails", "Time:")} #{time_str} (#{duration_str})"
    end
  end

  defp format_location_line(details),
    do: "#{dgettext("emails", "Location:")} #{Formatting.format_location(details)}"

  defp format_meeting_type_line(meeting_type) when is_binary(meeting_type) and meeting_type != "",
    do: "#{dgettext("emails", "Type:")} #{meeting_type}"

  defp format_meeting_type_line(_meeting_type), do: nil

  @doc "Formats a list of event field changes as plain text lines."
  @spec format_event_changes([{atom(), term(), term()}], String.t()) :: String.t()
  def format_event_changes(changes, locale \\ "en") do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      changes
      |> Enum.map(&format_single_change(&1, locale))
      |> Enum.filter(& &1)
      |> Enum.join("\n")
    end)
  end

  defp format_single_change({:title, from, to}, _locale) do
    "#{dgettext("emails", "Title:")} #{from || dgettext("emails", "(none)")} → #{to || dgettext("emails", "(none)")}"
  end

  defp format_single_change({:location, from, to}, _locale) do
    "#{dgettext("emails", "Location:")} #{from || dgettext("emails", "(none)")} → #{to || dgettext("emails", "(none)")}"
  end

  defp format_single_change({:description, _from, _to}, _locale) do
    dgettext("emails", "Description updated")
  end

  defp format_single_change({:time, from_start, to_start}, locale) do
    "#{dgettext("emails", "Time:")} #{Formatting.format_time_short(from_start, locale)} → #{Formatting.format_time_short(to_start, locale)}"
  end

  defp format_single_change(_other, _locale), do: nil
end
