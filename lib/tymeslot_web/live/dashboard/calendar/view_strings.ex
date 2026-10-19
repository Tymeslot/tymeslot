defmodule TymeslotWeb.Dashboard.Calendar.ViewStrings do
  @moduledoc """
  The client copy the month and agenda views and the phone's week strip
  draw with (`calendar/render_month.js`, `render_agenda.js`,
  `render_strip.js`), merged into `ClientStrings.build/1`. Placeholders are
  bound to themselves for the hook to fill, as `ClientStrings` does.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "The strings map, in the current Gettext locale."
  @spec strings() :: map()
  def strings do
    %{
      today: dgettext("dashboard_calendar", "Today"),
      agenda_label: dgettext("dashboard_calendar", "Agenda"),
      agenda_empty: dgettext("dashboard_calendar_views", "Nothing planned in these weeks."),
      agenda_until: dgettext("dashboard_calendar_views", "Until %{time}", time: "%{time}"),
      agenda_from: dgettext("dashboard_calendar_views", "From %{time}", time: "%{time}"),
      agenda_later: dgettext("dashboard_calendar_views", "Show later"),
      agenda_loading: dgettext("dashboard_calendar_views", "Loading more"),
      month_more:
        dgettext("dashboard_calendar_views", "More on %{date}: %{count}",
          count: "%{count}",
          date: "%{date}"
        ),
      month_attention:
        dgettext("dashboard_calendar_views", "includes something that needs your attention"),
      month_select:
        dgettext("dashboard_calendar_views", "%{date}, show this day's events", date: "%{date}"),
      day_events: dgettext("dashboard_calendar_views", "Events: %{count}", count: "%{count}"),
      strip_label: dgettext("dashboard_calendar_views", "Days of this week")
    }
  end
end
