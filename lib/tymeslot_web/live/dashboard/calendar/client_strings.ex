defmodule TymeslotWeb.Dashboard.Calendar.ClientStrings do
  @moduledoc """
  The copy the `CalendarCanvas` hook draws with, translated on the server and
  rendered into the canvas's `data-strings` attribute, so the JavaScript never
  holds English of its own. `%{name}` placeholders are filled by the hook.
  Weekdays are Monday first, as the hook indexes them by ISO weekday.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Helpers.LocaleFormat

  @doc """
  The strings map for `locale`. Each placeholder is bound to itself, so
  Gettext leaves it in place for the hook without logging missing bindings.
  """
  @spec build(String.t()) :: map()
  def build(locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn -> strings(locale) end)
  end

  defp strings(locale) do
    [sunday | monday_to_saturday] = LocaleFormat.get_weekday_names(locale, :short)

    %{
      weekdays: monday_to_saturday ++ [sunday],
      months: LocaleFormat.get_month_names(locale, :short),
      all_day: dgettext("dashboard_calendar", "All day"),
      more: dgettext("dashboard_calendar", "more"),
      allday_more:
        dgettext("dashboard_calendar", "%{count} more all-day events on %{date}",
          count: "%{count}",
          date: "%{date}"
        ),
      also_here: dgettext("dashboard_calendar", "Also here: %{titles}", titles: "%{titles}"),
      shown_as_free: dgettext("dashboard_calendar", "shown as free"),
      ended: dgettext("dashboard_calendar", "ended"),
      waiting_to_sync: dgettext("dashboard_calendar", "waiting to sync"),
      early_hours:
        dgettext("dashboard_calendar", "Before %{time}: %{count}",
          time: "%{time}",
          count: "%{count}"
        ),
      show_early_hours:
        dgettext("dashboard_calendar", "Show the hours before %{time}", time: "%{time}"),
      fold_early_hours:
        dgettext("dashboard_calendar", "Fold the hours before %{time}", time: "%{time}"),
      open_day: dgettext("dashboard_calendar", "%{date}, open day view", date: "%{date}"),
      empty_day: dgettext("dashboard_calendar", "Nothing planned on this day."),
      empty_three_day: dgettext("dashboard_calendar", "Nothing planned on these days."),
      empty_week: dgettext("dashboard_calendar", "Nothing planned this week."),
      loading: dgettext("dashboard_calendar", "Loading calendar"),
      list_label: dgettext("dashboard_calendar", "Events at this time"),
      calendar_role: dgettext("dashboard_calendar", "calendar"),
      period_range:
        dgettext("dashboard_calendar", "%{from} to %{to}", from: "%{from}", to: "%{to}"),
      range_on_day:
        dgettext("dashboard_calendar", "%{date}, %{start} to %{finish}",
          date: "%{date}",
          start: "%{start}",
          finish: "%{finish}"
        ),
      moving:
        dgettext(
          "dashboard_calendar",
          "Moving %{title}, %{when}. Arrow keys move it, Shift with Up or Down changes how long it lasts, Enter saves, Escape cancels.",
          title: "%{title}",
          when: "%{when}"
        ),
      move_cancelled:
        dgettext("dashboard_calendar", "Move cancelled. %{title} stays at %{when}.",
          title: "%{title}",
          when: "%{when}"
        ),
      move_saving:
        dgettext("dashboard_calendar", "Saving %{title} at %{when}.",
          title: "%{title}",
          when: "%{when}"
        )
    }
  end
end
