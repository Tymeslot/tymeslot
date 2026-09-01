defmodule TymeslotWeb.Themes.Shared.LocalizationHelpers do
  @moduledoc """
  Localized formatting helpers for date, time, and durations.
  Used specifically within theme contexts to handle translation.
  """
  use Gettext, backend: TymeslotWeb.Gettext
  alias Calendar
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.Display
  alias TymeslotWeb.Helpers.LocaleFormat

  @doc """
  Groups time slots by period of day with translated period names.
  """
  @spec group_slots_by_period([String.t()]) :: [{String.t(), [String.t()]}]
  def group_slots_by_period(slots) do
    grouped = Display.group_slots_by_period(slots)

    [
      {dgettext("booking", "Early Morning"), Map.get(grouped, "Early Morning", [])},
      {dgettext("booking", "Morning"), Map.get(grouped, "Morning", [])},
      {dgettext("booking", "Afternoon"), Map.get(grouped, "Afternoon", [])},
      {dgettext("booking", "Evening"), Map.get(grouped, "Evening", [])},
      {dgettext("booking", "Late Night"), Map.get(grouped, "Late Night", [])}
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

      dgettext("booking", "%{weekday}, %{day} %{month} %{year} at %{time} %{timezone}",
        weekday: weekday,
        day: dt.day,
        month: month,
        year: dt.year,
        time: time_str,
        timezone: dt.zone_abbr
      )
    else
      _error ->
        dgettext("booking", "%{date} at %{time}", date: date, time: time)
    end
  end

  def format_booking_datetime(_date, _time, _timezone),
    do: dgettext("booking", "Invalid date/time")

  @doc """
  Formats meeting time with localization and timezone awareness.
  """
  @spec format_meeting_time(DateTime.t(), String.t()) :: String.t()
  def format_meeting_time(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} ->
        time_str = format_time_by_locale(shifted)
        dgettext("booking", "%{time} %{timezone}", time: time_str, timezone: shifted.zone_abbr)

      _other ->
        time_str = format_time_by_locale(datetime)
        dgettext("booking", "%{time} UTC", time: time_str)
    end
  end

  @doc """
  Formats a meeting start time for the payment return pages — localized and
  shifted into the attendee's timezone, so the confirmation shows the time the
  attendee will actually keep rather than raw UTC. Falls back to UTC if the
  timezone is missing or unknown, and to an empty string for an unusable value.
  """
  @spec format_meeting_datetime(DateTime.t() | NaiveDateTime.t() | nil, String.t() | nil) ::
          String.t()
  def format_meeting_datetime(start_time, timezone) do
    case to_attendee_datetime(start_time, timezone) do
      {:ok, dt} ->
        dgettext("booking", "%{day} %{month} %{year} at %{time} %{timezone}",
          day: dt.day,
          month: get_month_name(dt.month),
          year: dt.year,
          time: format_time_by_locale(dt),
          timezone: dt.zone_abbr
        )

      :error ->
        ""
    end
  end

  @doc """
  Formats a meeting start time for lists that repeat it on every row.

  Same shift and fallback behaviour as `format_meeting_datetime/2`, but drops
  the year and the timezone abbreviation and adds the weekday. In a poll every
  candidate slot carries a date, so the year and zone are the same on every row
  and only cost width, while the weekday is exactly what a voter is choosing
  between. **The caller must state the timezone once for the list**, or the
  times are unlabelled.
  """
  @spec format_meeting_datetime_compact(
          DateTime.t() | NaiveDateTime.t() | nil,
          String.t() | nil
        ) :: String.t()
  def format_meeting_datetime_compact(start_time, timezone) do
    case to_attendee_datetime(start_time, timezone) do
      {:ok, dt} ->
        dgettext("booking", "%{weekday} %{day} %{month}, %{time}",
          weekday: get_weekday_name(Date.day_of_week(DateTime.to_date(dt))),
          day: dt.day,
          month: get_month_name(dt.month),
          time: format_time_by_locale(dt)
        )

      :error ->
        ""
    end
  end

  @doc """
  Shifts a meeting's stored UTC `start_time` into the zone it should be shown in.

  `start_time` is a `:utc_datetime`, so it must be shifted before formatting or
  the rendered clock is UTC. The returned struct carries the zone it actually
  landed in (`time_zone`), which is what callers must label it with: when
  `timezone` is nil, empty, or unresolvable the value stays UTC, and labelling
  it with the requested zone would assert a time that is not that time.
  """
  @spec to_attendee_datetime(DateTime.t() | NaiveDateTime.t() | nil, String.t() | nil) ::
          {:ok, DateTime.t()} | :error
  def to_attendee_datetime(%DateTime{} = dt, timezone), do: {:ok, shift_or_keep(dt, timezone)}

  def to_attendee_datetime(%NaiveDateTime{} = naive, timezone) do
    case DateTime.from_naive(naive, "Etc/UTC") do
      {:ok, dt} -> {:ok, shift_or_keep(dt, timezone)}
      _error -> :error
    end
  end

  def to_attendee_datetime(_other, _timezone), do: :error

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
    dgettext("booking", "%{month} %{day}, %{year}", month: month, day: date.day, year: date.year)
  end

  @spec format_date(DateTime.t()) :: String.t()
  def format_date(%DateTime{} = datetime) do
    datetime |> DateTime.to_date() |> format_date()
  end

  @doc """
  Builds a full, screen-reader-friendly date label — the localized weekday
  followed by the localized date, e.g. "Monday, July 15, 2026". Accepts an ISO
  date string (as carried in the calendar day maps) or a `Date`, and falls back
  to the raw input on a parse failure so a day button is never left unlabelled.
  """
  @spec format_full_date_label(String.t() | Date.t() | nil) :: String.t()
  def format_full_date_label(nil), do: ""

  def format_full_date_label(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> format_full_date_label(date)
      _other -> date_string
    end
  end

  def format_full_date_label(%Date{} = date) do
    dgettext("booking", "%{weekday}, %{date}",
      weekday: get_weekday_name(Date.day_of_week(date)),
      date: format_date(date)
    )
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
        dgettext("booking", "Unknown duration")
    end
  end

  @spec format_duration(integer()) :: String.t()
  def format_duration(minutes) when is_integer(minutes) do
    format_minutes(minutes)
  end

  @spec format_duration(any()) :: String.t()
  def format_duration(_other), do: dgettext("booking", "Unknown duration")

  @doc """
  Gets month name translated.
  """
  @spec get_month_name(integer()) :: String.t()
  def get_month_name(month) do
    case month do
      1 -> dgettext("booking", "January")
      2 -> dgettext("booking", "February")
      3 -> dgettext("booking", "March")
      4 -> dgettext("booking", "April")
      5 -> dgettext("booking", "May")
      6 -> dgettext("booking", "June")
      7 -> dgettext("booking", "July")
      8 -> dgettext("booking", "August")
      9 -> dgettext("booking", "September")
      10 -> dgettext("booking", "October")
      11 -> dgettext("booking", "November")
      12 -> dgettext("booking", "December")
    end
  end

  @doc """
  Gets weekday name translated.
  """
  @spec get_weekday_name(integer()) :: String.t()
  def get_weekday_name(day) do
    case day do
      1 -> dgettext("booking", "Monday")
      2 -> dgettext("booking", "Tuesday")
      3 -> dgettext("booking", "Wednesday")
      4 -> dgettext("booking", "Thursday")
      5 -> dgettext("booking", "Friday")
      6 -> dgettext("booking", "Saturday")
      7 -> dgettext("booking", "Sunday")
    end
  end

  @doc """
  Gets short weekday name translated.
  """
  @spec day_name_short(integer()) :: String.t()
  def day_name_short(day_of_week) do
    case day_of_week do
      1 -> dgettext("booking", "MON")
      2 -> dgettext("booking", "TUE")
      3 -> dgettext("booking", "WED")
      4 -> dgettext("booking", "THU")
      5 -> dgettext("booking", "FRI")
      6 -> dgettext("booking", "SAT")
      7 -> dgettext("booking", "SUN")
    end
  end

  @doc """
  Formats a time on the clock the visitor's language uses.

  The booking page is read by attendees, who never saw the organiser's clock
  setting and are frequently reading in a different language, so the visitor's
  own locale decides here. `LocaleFormat` holds that mapping and is what the
  confirmation email already uses, so the page and the email agree.

  This previously resolved the clock through a `"time_format_type"` msgid, which
  meant any translator could change how times render by editing what looked like
  a normal string, and several catalogues had: "24 Std.", "24 год".

  Takes anything with a clock face, `Time` as readily as `DateTime`: an hour
  label and a bare interval example carry no date, and only the clock fields
  are read.
  """
  @spec format_time_by_locale(Calendar.time()) :: String.t()
  def format_time_by_locale(time) do
    LocaleFormat.format_time(time, Gettext.get_locale(TymeslotWeb.Gettext))
  end

  @doc """
  Gets month and year display string.
  """
  @spec get_month_year_display(integer(), integer()) :: String.t()
  def get_month_year_display(year, month) do
    month_name = get_month_name(month)
    dgettext("booking", "%{month} %{year}", month: month_name, year: year)
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
        dgettext("booking", "%{month} %{year}",
          month: get_month_name(week_start.month),
          year: week_start.year
        )

      week_start.year == week_end.year ->
        dgettext("booking", "%{start_month} - %{end_month} %{year}",
          start_month: get_month_name(week_start.month),
          end_month: get_month_name(week_end.month),
          year: week_start.year
        )

      true ->
        dgettext("booking", "%{start_month} %{start_year} - %{end_month} %{end_year}",
          start_month: get_month_name(week_start.month),
          start_year: week_start.year,
          end_month: get_month_name(week_end.month),
          end_year: week_end.year
        )
    end
  end

  # Internal helpers

  defp format_minutes(1), do: dgettext("booking", "1 minute")

  defp format_minutes(minutes) when minutes < 60,
    do: dgettext("booking", "%{minutes} minutes", minutes: minutes)

  defp format_minutes(60), do: dgettext("booking", "1 hour")

  defp format_minutes(minutes) when rem(minutes, 60) == 0 do
    hours = div(minutes, 60)
    dgettext("booking", "%{count} hours", count: hours)
  end

  defp format_minutes(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)

    hour_text =
      if hours == 1,
        do: dgettext("booking", "1 hour"),
        else: dgettext("booking", "%{count} hours", count: hours)

    minute_text =
      if mins == 1,
        do: dgettext("booking", "1 minute"),
        else: dgettext("booking", "%{count} minutes", count: mins)

    dgettext("booking", "%{hour_text} %{minute_text}",
      hour_text: hour_text,
      minute_text: minute_text
    )
  end

  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)

  defp shift_or_keep(dt, timezone) when is_binary(timezone) and timezone != "" do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, shifted} -> shifted
      _error -> dt
    end
  end

  defp shift_or_keep(dt, _timezone), do: dt
end
