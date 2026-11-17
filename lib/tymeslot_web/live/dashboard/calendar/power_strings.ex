defmodule TymeslotWeb.Dashboard.Calendar.PowerStrings do
  @moduledoc """
  The client copy of the calendar's power layer (the command bar, the
  shortcut help hint, the search reveal, calendar sets and week numbers),
  merged into `ClientStrings.build/1`. Every string is in the
  `dashboard_calendar_power` domain, and placeholders are bound to
  themselves for the hook to fill, as `ClientStrings` does.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "The strings map, in the current Gettext locale."
  @spec strings() :: map()
  def strings do
    %{
      set_applied:
        dgettext("dashboard_calendar_power", "Showing the %{name} set", name: "%{name}"),
      set_cleared: dgettext("dashboard_calendar_power", "Calendar set turned off"),
      week_number: dgettext("dashboard_calendar_power", "Week %{number}", number: "%{number}"),
      command_today: dgettext("dashboard_calendar", "Today"),
      command_next: dgettext("dashboard_calendar", "Next period"),
      command_previous: dgettext("dashboard_calendar", "Previous period"),
      command_new_event: dgettext("dashboard_calendar_editing", "New event"),
      command_day: dgettext("dashboard_calendar", "Day"),
      command_three_day: dgettext("dashboard_calendar", "3 days"),
      command_week: dgettext("dashboard_calendar", "Week"),
      command_month: dgettext("dashboard_calendar", "Month"),
      command_agenda: dgettext("dashboard_calendar", "Agenda"),
      command_bookable: dgettext("dashboard_calendar_power", "Show or hide bookable times"),
      command_show_all: dgettext("dashboard_calendar", "Show all calendars"),
      command_shortcuts: dgettext("dashboard_calendar", "Keyboard shortcuts"),
      command_focus: dgettext("dashboard_calendar_power", "Focus mode"),
      command_leave_focus: dgettext("dashboard_calendar_power", "Leave focus mode"),
      command_compact: dgettext("dashboard_calendar_power", "Use compact density"),
      command_comfortable: dgettext("dashboard_calendar_power", "Use comfortable density"),
      command_clock_12: dgettext("dashboard_calendar_power", "Use the 12-hour clock"),
      command_clock_24: dgettext("dashboard_calendar_power", "Use the 24-hour clock"),
      command_week_sunday: dgettext("dashboard_calendar_power", "Start weeks on Sunday"),
      command_week_monday: dgettext("dashboard_calendar_power", "Start weeks on Monday"),
      command_show_weekends: dgettext("dashboard_calendar_power", "Show weekends in week view"),
      command_hide_weekends: dgettext("dashboard_calendar_power", "Hide weekends in week view"),
      command_show_week_numbers: dgettext("dashboard_calendar_power", "Show week numbers"),
      command_hide_week_numbers: dgettext("dashboard_calendar_power", "Hide week numbers"),
      command_fold: dgettext("dashboard_calendar", "Fold early hours"),
      command_unfold: dgettext("dashboard_calendar_power", "Unfold early hours"),
      command_reminders_on: dgettext("dashboard_calendar_power", "Turn on desktop notifications"),
      command_reminders_off:
        dgettext("dashboard_calendar_power", "Turn off desktop notifications"),
      command_import: dgettext("dashboard_calendar_power", "Import an .ics file"),
      command_set: dgettext("dashboard_calendar_power", "Switch to %{name}", name: "%{name}"),
      command_leave_set: dgettext("dashboard_calendar_power", "Leave the calendar set"),
      command_goto: dgettext("dashboard_calendar_power", "Go to %{date}", date: "%{date}"),
      command_add: dgettext("dashboard_calendar_power", "Add “%{title}”", title: "%{title}"),
      reveal_missed: dgettext("dashboard_calendar_power", "That event isn't in view any more.")
    }
  end
end
