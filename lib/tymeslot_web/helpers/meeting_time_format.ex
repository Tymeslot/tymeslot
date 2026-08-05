defmodule TymeslotWeb.Helpers.MeetingTimeFormat do
  @moduledoc """
  Formats a meeting's start time for the public token-authenticated pages
  (guest RSVP, seat management).

  These pages render for a recipient who has no session and no locale
  preference of their own, so the string is built from the request's Gettext
  locale and an explicit timezone rather than from any stored profile setting.
  """

  alias TymeslotWeb.Helpers.LocaleFormat

  @doc """
  Renders `meeting.start_time` in `timezone`, suffixed with the zone it is
  shown in. Falls back to the stored UTC time when the zone cannot be
  resolved, so the page still states a time rather than nothing.
  """
  @spec format_when(map(), String.t() | nil) :: String.t()
  def format_when(meeting, timezone) do
    tz = timezone || "Etc/UTC"

    case DateTime.shift_zone(meeting.start_time, tz) do
      {:ok, dt} -> format_datetime(dt) <> " (#{tz})"
      _error -> format_datetime(meeting.start_time) <> " UTC"
    end
  end

  defp format_datetime(dt) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    weekday = LocaleFormat.format_weekday_name(Date.day_of_week(dt), locale, :full)
    month = LocaleFormat.format_month_name(dt.month, locale, :full)

    # A guest is an attendee: the weekday and month already follow their
    # language, so the clock beside them does too rather than staying 24-hour.
    "#{weekday}, #{dt.day} #{month} #{dt.year} · #{LocaleFormat.format_time(dt, locale)}"
  end
end
