defmodule Tymeslot.Integrations.Calendar.ICalBuilder.Alarms do
  @moduledoc """
  VALARM (reminder) serialisation for iCalendar events.

  Shared by both the legacy `ICalBuilder.build_event/1` path and the canonical
  `ICalBuilder.build_simple_event/2` CalDAV write path.
  """

  alias Tymeslot.Integrations.Calendar.Reminder

  @doc """
  Serialises a list of reminders into VALARM blocks, one per reminder.

  Returns an empty string when no reminders are present.
  """
  @spec build_reminders(map()) :: String.t()
  def build_reminders(%{reminders: reminders}) when is_list(reminders) do
    Enum.map_join(reminders, "\r\n", &build_reminder/1)
  end

  def build_reminders(_no_reminders), do: ""

  # The canonical reminder shape is `%{method: :popup | :email | :sms, minutes_before:}`
  # (emitted by the provider normalisers). `:popup` → DISPLAY, `:email` → EMAIL,
  # `:sms` → DISPLAY for the VALARM ACTION. A permissive fallback keeps any
  # legacy/raw reminder (e.g. a bare `minutes_before`, or the historical `:type`
  # key) building a DISPLAY alarm rather than crashing the whole iCal write.
  # Both atom-keyed and string-keyed maps are handled via Reminder.
  defp build_reminder(%{minutes_before: minutes, method: method}) do
    build_valarm(minutes, Reminder.ical_action(method))
  end

  defp build_reminder(%{minutes_before: minutes, type: type}) do
    build_valarm(minutes, String.upcase(to_string(type)))
  end

  defp build_reminder(%{minutes_before: minutes}) do
    build_valarm(minutes, "DISPLAY")
  end

  # String-keyed reminders round-tripped through the JSONB cache column.
  defp build_reminder(%{"minutes_before" => minutes} = reminder) do
    build_valarm(minutes, Reminder.ical_action(Reminder.method(reminder)))
  end

  defp build_valarm(minutes, action) do
    String.trim("""
    BEGIN:VALARM
    TRIGGER:-PT#{minutes}M
    ACTION:#{action}
    DESCRIPTION:Reminder
    END:VALARM
    """)
  end
end
