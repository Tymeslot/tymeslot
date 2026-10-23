defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Alarms do
  @moduledoc """
  VALARM (reminder) serialisation for iCalendar events.

  Used by the `ICalBuilder.build_simple_event/3` CalDAV write path and by the
  patcher when a payload replaces an event's reminders.

  RFC 5545 §3.6.6 requires an `EMAIL` alarm to carry a `SUMMARY` (the mail's
  subject) and at least one `ATTENDEE` (its recipient). The recipient is the
  event's organiser, the calendar's owner, which is who set the alert; an
  email reminder written where no organiser address is known degrades to a
  `DISPLAY` alarm rather than an invalid `EMAIL` one.
  """

  alias Tymeslot.Integrations.Calendar.ICalBuilder.Format
  alias Tymeslot.Integrations.Calendar.Reminder

  @typedoc """
  What an `EMAIL` alarm needs beyond its trigger: the recipient's address and
  the subject, already escaped as an iCalendar TEXT value.
  """
  @type email_context :: %{recipient: String.t() | nil, summary: String.t()}

  @doc """
  Serialises a list of reminders into VALARM blocks, one per reminder, taking
  the email context from the event's own `:organizer_email` and `:summary`.

  Returns an empty string when no reminders are present.
  """
  @spec build_reminders(map()) :: String.t()
  def build_reminders(event_data) do
    build_reminders(event_data, %{
      recipient: Map.get(event_data, :organizer_email),
      summary: Format.escape_text(Map.get(event_data, :summary))
    })
  end

  @doc """
  As `build_reminders/1`, with the email context given explicitly: the
  patcher reads it from the stored document when the payload omits it.
  """
  @spec build_reminders(map(), email_context()) :: String.t()
  def build_reminders(%{reminders: reminders}, email) when is_list(reminders) do
    Enum.map_join(reminders, "\r\n", &(&1 |> reminder_alarm() |> build_valarm(email)))
  end

  def build_reminders(_no_reminders, _email), do: ""

  # The canonical reminder shape is `%{method: :popup | :email | :sms, minutes_before:}`
  # (emitted by the provider normalisers). `:popup` → DISPLAY, `:email` → EMAIL,
  # `:sms` → DISPLAY for the VALARM ACTION. A permissive fallback keeps any
  # legacy/raw reminder (e.g. a bare `minutes_before`, or the historical `:type`
  # key) building a DISPLAY alarm rather than crashing the whole iCal write.
  # Both atom-keyed and string-keyed maps are handled via Reminder.
  defp reminder_alarm(%{minutes_before: minutes, method: method}),
    do: {minutes, Reminder.ical_action(method)}

  defp reminder_alarm(%{minutes_before: minutes, type: type}),
    do: {minutes, String.upcase(to_string(type))}

  defp reminder_alarm(%{minutes_before: minutes}), do: {minutes, "DISPLAY"}

  # String-keyed reminders round-tripped through the JSONB cache column.
  defp reminder_alarm(%{"minutes_before" => minutes} = reminder),
    do: {minutes, Reminder.ical_action(Reminder.method(reminder))}

  defp build_valarm({minutes, "EMAIL"}, %{recipient: recipient, summary: summary})
       when is_binary(recipient) and recipient != "" do
    summary = if summary == "", do: "Reminder", else: summary

    String.trim("""
    BEGIN:VALARM
    TRIGGER:-PT#{minutes}M
    ACTION:EMAIL
    SUMMARY:#{summary}
    DESCRIPTION:Reminder
    ATTENDEE:mailto:#{Format.sanitize_ical_value(recipient)}
    END:VALARM
    """)
  end

  defp build_valarm({minutes, "EMAIL"}, _no_recipient),
    do: build_valarm({minutes, "DISPLAY"}, nil)

  defp build_valarm({minutes, action}, _email) do
    String.trim("""
    BEGIN:VALARM
    TRIGGER:-PT#{minutes}M
    ACTION:#{action}
    DESCRIPTION:Reminder
    END:VALARM
    """)
  end
end
