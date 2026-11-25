defmodule TymeslotWeb.Dashboard.Calendar.ClientStrings do
  @moduledoc """
  The copy the `CalendarCanvas` hook draws with, translated on the server and
  rendered into the canvas's `data-strings` attribute, so the JavaScript never
  holds English of its own. `%{name}` placeholders are filled by the hook.
  Weekdays are Monday first, as the hook indexes them by ISO weekday.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.Calendar.BadgeStrings
  alias TymeslotWeb.Dashboard.Calendar.BookableStrings
  alias TymeslotWeb.Dashboard.Calendar.PowerStrings
  alias TymeslotWeb.Dashboard.Calendar.ViewStrings
  alias TymeslotWeb.Helpers.LocaleFormat

  @doc """
  The strings map for `locale`. Each placeholder is bound to itself, so
  Gettext leaves it in place for the hook without logging missing bindings.
  """
  @spec build(String.t()) :: map()
  def build(locale) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
      locale
      |> strings()
      |> Map.merge(request_strings())
      |> Map.merge(opening_strings())
      |> Map.merge(BookableStrings.strings())
      |> Map.merge(BadgeStrings.strings())
      |> Map.merge(ViewStrings.strings())
      |> Map.merge(PowerStrings.strings())
    end)
  end

  defp strings(locale) do
    [sunday | monday_to_saturday] = LocaleFormat.get_weekday_names(locale, :short)

    %{
      weekdays: monday_to_saturday ++ [sunday],
      months: LocaleFormat.get_month_names(locale, :short),
      first_of_month: LocaleFormat.format_day_of_month(1, locale),
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
        ),
      new_event: dgettext("dashboard_calendar_editing", "New event"),
      quick_create_label: dgettext("dashboard_calendar_editing", "New event"),
      quick_create_placeholder:
        dgettext("dashboard_calendar_editing", "Title, or: lunch 13:00 /personal"),
      quick_create_hint:
        dgettext(
          "dashboard_calendar_editing",
          "Enter saves, Esc cancels. Type a day and time, /calendar, @email or ;place."
        ),
      save: dgettext("dashboard_calendar_editing", "Save"),
      save_and_invite: dgettext("dashboard_calendar_editing", "Save and invite"),
      more_options: dgettext("dashboard_calendar_editing", "More options"),
      show_as: dgettext("dashboard_calendar_editing", "Show as"),
      busy: dgettext("dashboard_calendar_editing", "Busy"),
      free: dgettext("dashboard_calendar_editing", "Free"),
      date_chip: dgettext("dashboard_calendar_editing", "Date"),
      start_chip: dgettext("dashboard_calendar_editing", "Starts"),
      end_chip: dgettext("dashboard_calendar_editing", "Ends"),
      time_to: dgettext("dashboard_calendar_editing", "to"),
      all_day_chip: dgettext("dashboard_calendar_editing", "All day"),
      calendar_chip: dgettext("dashboard_calendar_editing", "Calendar"),
      place_chip: dgettext("dashboard_calendar_editing", "Place"),
      guests_chip: dgettext("dashboard_calendar_editing", "Guests"),
      saving_draft: dgettext("dashboard_calendar_editing", "Saving…"),
      create_refused:
        dgettext("dashboard_calendar_editing", "Couldn't add the event. Please try again."),
      create_unconfirmed:
        dgettext("dashboard_calendar_editing", "Couldn't confirm the save. Check your calendar."),
      dismiss: dgettext("dashboard_calendar", "Dismiss")
    }
  end

  # Quick create's "Open for booking" kind (see `OpenBooking`).
  defp opening_strings do
    %{
      kind_label: dgettext("dashboard_calendar_booking", "What to add"),
      kind_event: dgettext("dashboard_calendar_booking", "Event"),
      kind_open: dgettext("dashboard_calendar_booking", "Open for booking"),
      meeting_type_chip: dgettext("dashboard_calendar_booking", "Meeting type"),
      repeat_label: dgettext("dashboard_calendar_booking", "Repeat"),
      just_this_once: dgettext("dashboard_calendar_booking", "Just this once"),
      every_week: dgettext("dashboard_calendar_booking", "Every week"),
      open_save: dgettext("dashboard_calendar_booking", "Open for booking"),
      open_hint:
        dgettext(
          "dashboard_calendar_booking",
          "Guests can book this time on your booking page. The day's hours widen to include it."
        ),
      open_draft_title:
        dgettext("dashboard_calendar_booking", "Open for %{name}", name: "%{name}"),
      open_refused:
        dgettext("dashboard_calendar_booking", "Couldn't open that time. Please try again."),
      open_unconfirmed:
        dgettext(
          "dashboard_calendar_booking",
          "Couldn't confirm the change. Check your bookable times."
        ),
      # Quick create cannot make a meeting, but More options can, without a
      # calendar.
      no_calendar_note:
        dgettext(
          "dashboard_calendar_booking",
          "Connect a calendar to add events, or use More options to send a Tymeslot meeting."
        ),
      read_only_calendars_note:
        dgettext(
          "dashboard_calendar_booking",
          "Your calendars are read-only. Connect one you can write to, or use More options to send a Tymeslot meeting."
        )
    }
  end

  # What a booking request is drawn with: its flag, its accessible names, and
  # what the "+N" chip's warning dot stands for.
  defp request_strings do
    %{
      request: dgettext("dashboard_calendar_booking", "Request"),
      request_expired: dgettext("dashboard_calendar_booking", "Expired"),
      request_aria: dgettext("dashboard_calendar_booking", "request waiting for your answer"),
      request_expired_aria:
        dgettext("dashboard_calendar_booking", "request expired without an answer"),
      request_waiting: dgettext("dashboard_calendar_booking", "a request waiting for your answer")
    }
  end
end
