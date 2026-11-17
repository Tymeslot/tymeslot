defmodule TymeslotWeb.Dashboard.Calendar.BookableStrings do
  @moduledoc """
  The bookable-times layer's share of the `CalendarCanvas` hook's copy,
  merged into `ClientStrings.build/1` under the caller's locale: the band
  label, the next-bookable note, the failed-load note and the explainer
  (Copy free times, Block this time). Placeholders are
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
      bookable_error:
        dgettext("dashboard_calendar_booking", "Couldn't load your bookable times."),
      bookable_title: dgettext("dashboard_calendar_booking", "Bookable times"),
      bookable_explainer:
        dgettext(
          "dashboard_calendar_booking",
          "Guests can book %{meeting_type} in the hatched times. Busy events, buffers and your notice period are already taken out, so this is exactly what your booking page offers.",
          meeting_type: "%{meeting_type}"
        ),
      bookable_hide_hint:
        dgettext("dashboard_calendar_booking", "Press B to hide bookable times."),
      copy_free_times: dgettext("dashboard_calendar_booking", "Copy free times"),
      block_this_time: dgettext("dashboard_calendar_booking", "Block this time"),
      blocking: dgettext("dashboard_calendar_booking", "Blocking…"),
      block_refused:
        dgettext("dashboard_calendar_booking", "Couldn't block that time. Please try again."),
      copied: dgettext("dashboard_calendar_booking", "Free times for these days copied."),
      copy_failed:
        dgettext(
          "dashboard_calendar_booking",
          "Couldn't copy. Your browser blocked the clipboard."
        ),
      free_times_day:
        dgettext("dashboard_calendar_booking", "%{date}: %{times}",
          date: "%{date}",
          times: "%{times}"
        ),
      free_times_zone:
        dgettext("dashboard_calendar_booking", "Times in %{zone}", zone: "%{zone}"),
      free_times_none: dgettext("dashboard_calendar_booking", "No bookable times on these days."),
      time_range:
        dgettext("dashboard_calendar_booking", "%{start} to %{finish}",
          start: "%{start}",
          finish: "%{finish}"
        )
    }
  end
end
