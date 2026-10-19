defmodule Tymeslot.Emails.Shared.TextBodyHelper do
  @moduledoc """
  Helper functions for generating consistent text body content in email templates.
  """

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Emails.Shared.{Formatting, Sanitise}

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  The plain-text meeting details, from the same meeting-details map the HTML
  card receives (`Tymeslot.Emails.Shared.MeetingComponents.meeting_details_table/2`):
  the recipient's date, time and zone, duration, location and meeting type.
  The time line is `Tymeslot.Emails.Shared.Formatting.format_meeting_time/2`,
  word for word what the card shows.
  """
  @spec format_meeting_details(map(), String.t()) :: String.t()
  def format_meeting_details(meeting_details, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      [
        "#{dgettext("emails", "Date:")} #{Formatting.format_date(meeting_details.date, locale)}",
        format_time_line(meeting_details, locale),
        format_duration_line(meeting_details, locale),
        format_location_line(meeting_details),
        Formatting.location_note(meeting_details),
        format_meeting_type_line(Map.get(meeting_details, :meeting_type))
      ]
      |> Enum.filter(& &1)
      |> Enum.join("\n")
    end)
  end

  @doc """
  The note under an in-person location whose address is arranged after
  booking, as a line of its own to append straight to a text body's location
  line; empty for any other location.
  Must be called within a `Gettext.with_locale` block.
  """
  @spec location_note_line(map()) :: String.t()
  def location_note_line(details) do
    case Formatting.location_note(details) do
      nil -> ""
      note -> "\n" <> note
    end
  end

  @doc """
  The join link block of a text body, or `""` unless `meeting_url` is a web
  address (`Sanitise.safe_web_url?/1`): a bare room id or a `mailto:` address
  is no way into the meeting, as the HTML join section also refuses.
  """
  @spec format_video_section(String.t() | nil, String.t()) :: String.t()
  def format_video_section(meeting_url, locale) do
    if Sanitise.safe_web_url?(meeting_url),
      do: video_section(meeting_url, locale),
      else: ""
  end

  defp video_section(meeting_url, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      """

      #{dgettext("emails", "JOIN VIDEO MEETING:")}
      #{meeting_url}
      #{dgettext("emails", "The meeting room opens 5 minutes before your scheduled time.")}
      """
    end)
  end

  @doc """
  The ACTIONS block of a text body: one line per action the payload carries a
  linkable URL for (`Sanitise.safe_url?/1`), or `""` when there is none.
  """
  @spec format_action_links(Tymeslot.Emails.EmailService.appointment_details(), String.t()) ::
          String.t()
  def format_action_links(appointment_details, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      lines =
        for {label, url} <- [
              {dgettext("emails", "Reschedule:"), Map.get(appointment_details, :reschedule_url)},
              {dgettext("emails", "Cancel:"), Map.get(appointment_details, :cancel_url)},
              {dgettext("emails", "Open in dashboard:"),
               Map.get(appointment_details, :dashboard_url)}
            ],
            Sanitise.safe_url?(url),
            do: "#{label} #{url}"

      case lines do
        [] -> ""
        lines -> "\n#{dgettext("emails", "ACTIONS:")}\n#{Enum.join(lines, "\n")}\n"
      end
    end)
  end

  @doc """
  A guest's answer links as a text block under `heading`, with an optional
  closing `footer`: one line per answer the payload carries a linkable URL
  for, or `""` when there is none, so no heading asks a question the email
  gives no way to answer. Mirrors `TemplateHelper.guest_answer_actions/1`.
  Must be called within a `Gettext.with_locale` block.
  """
  @spec format_guest_answers(map(), String.t(), String.t() | nil) :: String.t()
  def format_guest_answers(appointment_details, heading, footer \\ nil) do
    lines =
      for {url, line} <- [
            {Map.get(appointment_details, :guest_accept_url),
             &dgettext("emails_booking", "Yes, I'll attend: %{url}", url: &1)},
            {Map.get(appointment_details, :guest_decline_url),
             &dgettext("emails_booking", "Can't make it: %{url}", url: &1)}
          ],
          Sanitise.safe_url?(url),
          do: line.(url)

    case lines do
      [] -> ""
      lines -> "\n\n#{heading}\n#{Enum.join(lines, "\n")}#{if footer, do: "\n\n" <> footer}"
    end
  end

  @doc """
  A list as plain-text bullet lines, one item each: the text counterpart of
  `Tymeslot.Emails.Shared.Text.bullet_list/1`, which marks its items the
  same way.
  """
  @spec format_bullets([String.t()]) :: String.t()
  def format_bullets(items), do: Enum.map_join(items, "\n", &"• #{&1}")

  @doc """
  The organiser's note to the guest, as a plain-text block, or `""` when the
  meeting carries none.
  """
  @spec format_organizer_note(Tymeslot.Emails.EmailService.appointment_details(), String.t()) ::
          String.t()
  def format_organizer_note(%{organizer_note: note}, locale)
      when is_binary(note) and note != "" do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      "\n\n#{dgettext("emails", "NOTE FROM THE ORGANISER:")}\n\"#{note}\""
    end)
  end

  def format_organizer_note(_appointment_details, _locale), do: ""

  @doc """
  Formats attendee information for text body.
  """
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

  defp format_time_line(meeting_details, locale) do
    case Formatting.format_meeting_time(meeting_details, locale) do
      nil -> nil
      line -> "#{dgettext("emails", "Time:")} #{line}"
    end
  end

  defp format_duration_line(meeting_details, locale) do
    case Formatting.format_meeting_duration(meeting_details, locale) do
      "" -> nil
      duration -> "#{dgettext("emails", "Duration:")} #{duration}"
    end
  end

  defp format_location_line(details),
    do: "#{dgettext("emails", "Location:")} #{Formatting.format_location(details)}"

  defp format_meeting_type_line(meeting_type) when is_binary(meeting_type) and meeting_type != "",
    do: "#{dgettext("emails", "Type:")} #{meeting_type}"

  defp format_meeting_type_line(_meeting_type), do: nil

  @doc "Formats a list of event field changes as plain text lines."
  @spec format_event_changes([{atom(), term(), term()}], String.t()) :: String.t()
  def format_event_changes(changes, locale) do
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

  @doc """
  Formats the current details of an event whose previous state was never
  recorded, from the `{field, nil, current}` list a first notification
  carries: each line states what the field is now, with no arrow claiming a
  previous value.
  """
  @spec format_event_details([{atom(), term(), term()}], String.t()) :: String.t()
  def format_event_details(changes, locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      changes
      |> Enum.map(&format_current_detail(&1, locale))
      |> Enum.filter(& &1)
      |> Enum.join("\n")
    end)
  end

  defp format_current_detail({:title, _from, to}, _locale),
    do: "#{dgettext("emails", "Title:")} #{to}"

  defp format_current_detail({:location, _from, to}, _locale),
    do: "#{dgettext("emails", "Location:")} #{to}"

  defp format_current_detail({:description, _from, to}, _locale),
    do: "#{dgettext("emails", "Description:")} #{Formatting.plain_excerpt(to)}"

  defp format_current_detail({:time, _from, to}, locale),
    do: "#{dgettext("emails", "Time:")} #{Formatting.format_time_short(to, locale)}"

  defp format_current_detail(_other, _locale), do: nil
end
