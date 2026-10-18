defmodule TymeslotWeb.Dashboard.Calendar.BookableStrings do
  @moduledoc """
  The bookable-times layer's share of the `CalendarCanvas` hook's copy,
  merged into `ClientStrings.build/1` under the caller's locale: the band
  label, the next-bookable note and the failed-load note. Placeholders are
  bound to themselves for the hook to fill.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc "The layer's strings, in the current Gettext locale."
  @spec strings() :: map()
  def strings do
    %{
      bookable: dgettext("dashboard_calendar_booking", "Bookable"),
      bookable_label:
        dgettext(
          "dashboard_calendar_booking",
          "%{date}: bookable times for %{meeting_type}. Show what this means",
          date: "%{date}",
          meeting_type: "%{meeting_type}"
        ),
      next_bookable:
        dgettext("dashboard_calendar_booking", "Next bookable time: %{when}", when: "%{when}"),
      show: dgettext("dashboard_calendar_booking", "Show"),
      bookable_error: dgettext("dashboard_calendar_booking", "Couldn't load your bookable times.")
    }
  end
end
