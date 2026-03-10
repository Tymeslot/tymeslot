defmodule TymeslotWeb.Themes.Shared.LocalizationHelpers do
  @moduledoc """
  Localized formatting helpers for date, time, and durations.
  Used specifically within theme contexts to handle translation.
  """
  use Gettext, backend: TymeslotWeb.Gettext
  alias Calendar
  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  Groups time slots by period of day with translated period names.
  """
  @spec group_slots_by_period([String.t()]) :: [{String.t(), [String.t()]}]
  def group_slots_by_period(slots) do
    grouped = DateTimeUtils.group_slots_by_period(slots)

    [
      {gettext("Night"), Map.get(grouped, "Night", [])},
      {gettext("Morning"), Map.get(grouped, "Morning", [])},
      {gettext("Afternoon"), Map.get(grouped, "Afternoon", [])},
      {gettext("Evening"), Map.get(grouped, "Evening", [])}
    ]
  end

  @doc """
  Formats booking datetime for display with localized names.
  """
  @spec format_booking_datetime(String.t(), String.t(), String.t()) :: String.t()
  def format_booking_datetime(date, time, timezone)
      when is_binary(date) and is_binary(time) and is_binary(timezone) do
    with {:ok, date_struct} <- parse_date(date),
         {:ok, time_obj} <- DateTimeUtils.parse_time_string(time),
         {:ok, naive_dt} <- NaiveDateTime.new(date_struct, time_obj),
         {:ok, dt} <- DateTime.from_naive(naive_dt, timezone) do
      weekday = get_weekday_name(Date.day_of_week(DateTime.to_date(dt)))
      month = get_month_name(dt.month)
      time_str = format_time_by_locale(dt)

      gettext("%{weekday}, %{day} %{month} %{year} at %{time} %{timezone}",
        weekday: weekday,
        day: dt.day,
        month: month,
        year: dt.year,
        time: time_str,
        timezone: dt.zone_abbr
      )
    else
      _error ->
        gettext("%{date} at %{time}", date: date, time: time)
    end
  end

  def format_booking_datetime(_date, _time, _timezone),
    do: gettext("Invalid date/time")

  @doc """
  Formats meeting time with localization and timezone awareness.
  """
  @spec format_meeting_time(DateTime.t(), String.t()) :: String.t()
  def format_meeting_time(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} ->
        time_str = format_time_by_locale(shifted)
        gettext("%{time} %{timezone}", time: time_str, timezone: shifted.zone_abbr)

      _other ->
        time_str = format_time_by_locale(datetime)
        gettext("%{time} UTC", time: time_str)
    end
  end

  @doc """
  Formats date string or struct for display.
  """
  @spec format_date(String.t() | Date.t() | DateTime.t() | nil) :: String.t()
  def format_date(nil), do: ""

  def format_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> format_date(date)
      _other -> date_string
    end
  end

  @spec format_date(Date.t()) :: String.t()
  def format_date(%Date{} = date) do
    month = get_month_name(date.month)
    gettext("%{month} %{day}, %{year}", month: month, day: date.day, year: date.year)
  end

  @spec format_date(DateTime.t()) :: String.t()
  def format_date(%DateTime{} = datetime) do
    datetime |> DateTime.to_date() |> format_date()
  end

  @doc """
  Formats duration for display.
  """
  @spec format_duration(String.t()) :: String.t()
  def format_duration(duration_string) when is_binary(duration_string) do
    cond do
      # Handle "30min" format
      match = Regex.run(~r/^(\d+)min$/, duration_string) ->
        [_first, minutes_str] = match
        minutes = String.to_integer(minutes_str)
        format_minutes(minutes)

      # Handle "30-minutes" slug format
      match = Regex.run(~r/^(\d+)-minutes?$/, duration_string) ->
        [_first, minutes_str] = match
        minutes = String.to_integer(minutes_str)
        format_minutes(minutes)

      true ->
        gettext("Unknown duration")
    end
  end

  @spec format_duration(integer()) :: String.t()
  def format_duration(minutes) when is_integer(minutes) do
    format_minutes(minutes)
  end

  @spec format_duration(any()) :: String.t()
  def format_duration(_other), do: gettext("Unknown duration")

  @doc """
  Gets month name translated.
  """
  @spec get_month_name(integer()) :: String.t()
  def get_month_name(month) do
    case month do
      1 -> gettext("January")
      2 -> gettext("February")
      3 -> gettext("March")
      4 -> gettext("April")
      5 -> gettext("May")
      6 -> gettext("June")
      7 -> gettext("July")
      8 -> gettext("August")
      9 -> gettext("September")
      10 -> gettext("October")
      11 -> gettext("November")
      12 -> gettext("December")
    end
  end

  @doc """
  Gets weekday name translated.
  """
  @spec get_weekday_name(integer()) :: String.t()
  def get_weekday_name(day) do
    case day do
      1 -> gettext("Monday")
      2 -> gettext("Tuesday")
      3 -> gettext("Wednesday")
      4 -> gettext("Thursday")
      5 -> gettext("Friday")
      6 -> gettext("Saturday")
      7 -> gettext("Sunday")
    end
  end

  @doc """
  Gets short weekday name translated.
  """
  @spec day_name_short(integer()) :: String.t()
  def day_name_short(day_of_week) do
    case day_of_week do
      1 -> gettext("MON")
      2 -> gettext("TUE")
      3 -> gettext("WED")
      4 -> gettext("THU")
      5 -> gettext("FRI")
      6 -> gettext("SAT")
      7 -> gettext("SUN")
    end
  end

  @doc """
  Formats time based on the current locale's preferred format (24h/12h).
  """
  @spec format_time_by_locale(DateTime.t()) :: String.t()
  def format_time_by_locale(dt) do
    case gettext("time_format_type") do
      "12h" -> Calendar.strftime(dt, "%-I:%M %p")
      _other -> Calendar.strftime(dt, "%H:%M")
    end
  end

  @doc """
  Gets month and year display string.
  """
  @spec get_month_year_display(integer(), integer()) :: String.t()
  def get_month_year_display(year, month) do
    month_name = get_month_name(month)
    gettext("%{month} %{year}", month: month_name, year: year)
  end

  @doc """
  Gets a display string for a week starting on `week_start`.

  Returns "March 2026" when the week falls within a single month,
  "March - April 2026" when it spans two months in the same year,
  or "December 2025 - January 2026" when it spans a year boundary.
  """
  @spec get_week_display(Date.t()) :: String.t()
  def get_week_display(week_start) do
    week_end = Date.add(week_start, 6)

    cond do
      week_start.month == week_end.month ->
        gettext("%{month} %{year}",
          month: get_month_name(week_start.month),
          year: week_start.year
        )

      week_start.year == week_end.year ->
        gettext("%{start_month} - %{end_month} %{year}",
          start_month: get_month_name(week_start.month),
          end_month: get_month_name(week_end.month),
          year: week_start.year
        )

      true ->
        gettext("%{start_month} %{start_year} - %{end_month} %{end_year}",
          start_month: get_month_name(week_start.month),
          start_year: week_start.year,
          end_month: get_month_name(week_end.month),
          end_year: week_end.year
        )
    end
  end

  # Internal helpers

  defp format_minutes(1), do: gettext("1 minute")

  defp format_minutes(minutes) when minutes < 60,
    do: gettext("%{minutes} minutes", minutes: minutes)

  defp format_minutes(60), do: gettext("1 hour")

  defp format_minutes(minutes) when rem(minutes, 60) == 0 do
    hours = div(minutes, 60)
    gettext("%{count} hours", count: hours)
  end

  defp format_minutes(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)

    hour_text =
      if hours == 1, do: gettext("1 hour"), else: gettext("%{count} hours", count: hours)

    minute_text =
      if mins == 1, do: gettext("1 minute"), else: gettext("%{count} minutes", count: mins)

    gettext("%{hour_text} %{minute_text}", hour_text: hour_text, minute_text: minute_text)
  end

  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)
end
