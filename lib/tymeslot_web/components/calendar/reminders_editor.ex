defmodule TymeslotWeb.Components.Calendar.RemindersEditor do
  @moduledoc """
  How the calendar labels a reminder: `reminder_label/1` for a saved
  reminder ("Notification 10 minutes before") and `minutes_label/1` for a
  lead time, which the side panel's reminder select also labels the
  `ReminderForm.reminder_minutes_presets/0` lead times with. Reminders are
  synced to the calendar provider, which fires the alert on the user's own
  devices; Tymeslot does not fire them itself.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.Reminder

  @doc """
  Returns a human-readable label for a reminder, e.g. "Notification 10 minutes before".

  Reads through `Reminder`, so a raw string-keyed reminder straight out of the
  JSONB cache column labels the same as a canonical atom-keyed one. Rendering is
  the last place that should fail on a shape: a mislabelled reminder is a far
  cheaper outcome than a crashed calendar.
  """
  @spec reminder_label(map()) :: String.t()
  def reminder_label(%{} = reminder) do
    dgettext("dashboard_calendar_events", "%{method} %{minutes}",
      method: method_label(Reminder.method(reminder)),
      minutes: minutes_label(Reminder.minutes_before(reminder))
    )
  end

  defp method_label(:email), do: dgettext("dashboard_calendar_events", "Email")
  defp method_label(_popup_or_other), do: dgettext("dashboard_calendar_events", "Notification")

  @doc ~s(How a lead time reads in a reminder's label, such as "10 minutes before".)
  @spec minutes_label(term()) :: String.t()
  # A provider alarm whose trigger we could not parse reaches the cache without
  # a lead time. Say so rather than inventing one.
  def minutes_label(minutes) when not is_integer(minutes),
    do: dgettext("dashboard_calendar_events", "before the event")

  def minutes_label(1440), do: dgettext("dashboard_calendar_events", "1 day before")
  def minutes_label(60), do: dgettext("dashboard_calendar_events", "1 hour before")

  def minutes_label(minutes) when minutes >= 60 and rem(minutes, 60) == 0,
    do:
      dngettext(
        "dashboard_calendar_events",
        "%{count} hour before",
        "%{count} hours before",
        div(minutes, 60)
      )

  def minutes_label(minutes),
    do:
      dngettext(
        "dashboard_calendar_events",
        "%{count} minute before",
        "%{count} minutes before",
        minutes
      )
end
