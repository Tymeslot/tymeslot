defmodule TymeslotWeb.Dashboard.Calendar.ClientStrings do
  @moduledoc """
  The copy the `CalendarCanvas` hook draws with, translated on the server and
  rendered into the canvas's `data-strings` attribute, so the JavaScript never
  holds English of its own. `%{name}` placeholders are filled by the hook.
  Weekdays are Monday first, as the hook indexes them by ISO weekday.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Helpers.LocaleFormat

  @doc "The strings map for `locale`."
  @spec build(String.t()) :: map()
  def build(locale) do
    [sunday | monday_to_saturday] = LocaleFormat.get_weekday_names(locale, :short)

    %{
      weekdays: monday_to_saturday ++ [sunday],
      months: LocaleFormat.get_month_names(locale, :short),
      all_day: dgettext("dashboard_calendar", "All day"),
      more: dgettext("dashboard_calendar", "more"),
      also_here: dgettext("dashboard_calendar", "Also here: %{titles}"),
      shown_as_free: dgettext("dashboard_calendar", "shown as free"),
      ended: dgettext("dashboard_calendar", "ended"),
      waiting_to_sync: dgettext("dashboard_calendar", "waiting to sync"),
      early_hours: dgettext("dashboard_calendar", "Before %{time}: %{count}"),
      show_early_hours: dgettext("dashboard_calendar", "Show the hours before %{time}"),
      fold_early_hours: dgettext("dashboard_calendar", "Fold the hours before %{time}"),
      open_day: dgettext("dashboard_calendar", "%{date}, open day view"),
      empty_day: dgettext("dashboard_calendar", "Nothing planned on this day."),
      empty_three_day: dgettext("dashboard_calendar", "Nothing planned on these days."),
      empty_week: dgettext("dashboard_calendar", "Nothing planned this week."),
      loading: dgettext("dashboard_calendar", "Loading calendar"),
      list_label: dgettext("dashboard_calendar", "Events at this time")
    }
  end
end
