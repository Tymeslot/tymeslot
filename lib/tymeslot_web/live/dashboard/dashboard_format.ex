defmodule TymeslotWeb.Dashboard.DashboardFormat do
  @moduledoc """
  Date, time and duration wording for the organiser's dashboard.

  One module so the overview, the calendar and the bookings list say the same
  thing the same way. Every function takes the organiser's timezone, and those
  that print a clock take their resolved clock format (`"12h"`/`"24h"`, see
  `Tymeslot.Utils.DateTimeUtils.TimeFormat.resolve/2`) explicitly: the
  dashboard is theirs, so a caller that has not decided which clock to use
  should not compile. Weekday and month names, and their order, follow the
  current Gettext locale.

  A time range keeps each of its ends on one line: the spaces inside "11:00 AM"
  (and inside a date beside it) are non-breaking, as is the space before the
  en dash, so the only place a narrow column can wrap is after the dash.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Agenda.Entry
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  @nbsp " "

  @doc "The label for an event that lasts the whole day."
  @spec all_day() :: String.t()
  def all_day, do: dgettext("dashboard_common", "All day")

  @doc "An event's title, or the one label the dashboard uses for an untitled event."
  @spec title(String.t() | nil) :: String.t()
  def title(title) when is_binary(title) and title != "", do: title
  def title(_untitled), do: dgettext("dashboard_common", "(No title)")

  @doc """
  A clock time in the organiser's timezone and clock format: "2:30 PM", "14:30".
  """
  @spec clock(DateTime.t(), String.t(), String.t()) :: String.t()
  def clock(datetime, timezone, time_format),
    do: datetime |> local(timezone) |> TimeFormat.format(time_format)

  @doc """
  When an entry starts, as a clock time, or the all-day label.
  """
  @spec start_label(Entry.t(), String.t(), String.t()) :: String.t()
  def start_label(%Entry{all_day?: true}, _timezone, _time_format), do: all_day()

  def start_label(%Entry{} = entry, timezone, time_format),
    do: clock(entry.start_at, timezone, time_format)

  @doc """
  A start–end range in the organiser's timezone: "2:30 PM – 3:00 PM".

  A range whose ends fall on different local days names each day, so an
  overnight event does not read as running backwards:
  "Feb 5, 11:30 PM – Feb 6, 12:30 AM".
  """
  @spec time_range(DateTime.t(), DateTime.t(), String.t(), String.t()) :: String.t()
  def time_range(start_at, end_at, timezone, time_format) do
    local_start = local(start_at, timezone)
    local_end = local(end_at, timezone)

    {from, to} =
      if Date.compare(DateTime.to_date(local_start), DateTime.to_date(local_end)) == :eq do
        {TimeFormat.format(local_start, time_format), TimeFormat.format(local_end, time_format)}
      else
        {dated_clock(local_start, time_format), dated_clock(local_end, time_format)}
      end

    keep_together(from) <> @nbsp <> "– " <> keep_together(to)
  end

  @doc """
  An entry's time range, or the all-day label.
  """
  @spec entry_time_range(Entry.t(), String.t(), String.t()) :: String.t()
  def entry_time_range(%Entry{all_day?: true}, _timezone, _time_format), do: all_day()

  def entry_time_range(%Entry{} = entry, timezone, time_format),
    do: time_range(entry.start_at, entry.end_at, timezone, time_format)

  @doc """
  The day an entry occupies, relative to today where that reads better:
  "Today", "Tomorrow", otherwise a short date ("Mon Feb 5").

  An entry counts as today's while it covers today (`Entry.covers?/3`), so an
  overnight meeting still running reads as today's rather than yesterday's.
  """
  @spec day_label(Entry.t(), String.t()) :: String.t()
  def day_label(%Entry{} = entry, timezone) do
    today = local_date(DateTime.utc_now(), timezone)

    cond do
      Entry.covers?(entry, today, timezone) ->
        dgettext("dashboard_common", "Today")

      Entry.covers?(entry, Date.add(today, 1), timezone) ->
        dgettext("dashboard_common", "Tomorrow")

      true ->
        short_date(entry.day)
    end
  end

  @doc ~s(A compact date led by its weekday: "Mon Feb 5", "Mo 5. Feb".)
  @spec short_date(Date.t()) :: String.t()
  def short_date(date), do: LocaleFormat.format_short_weekday_date(date, locale())

  @doc ~s(A full date led by its weekday: "Monday, February 5, 2026", "Montag, 5. Februar 2026".)
  @spec long_date(Date.t()) :: String.t()
  def long_date(date), do: LocaleFormat.format_weekday_date(date, locale())

  @doc """
  The full date an entry falls on. A multi-day all-day entry names its first
  and last days; its `end_at` is the exclusive midnight after the last.
  """
  @spec date_label(Entry.t(), String.t()) :: String.t()
  def date_label(%Entry{all_day?: true} = entry, timezone) do
    first = local_date(entry.start_at, timezone)
    last = entry.end_at |> local_date(timezone) |> Date.add(-1)

    case Date.compare(first, last) do
      :lt -> "#{long_date(first)} – #{long_date(last)}"
      _same_day -> long_date(first)
    end
  end

  def date_label(%Entry{} = entry, timezone),
    do: entry.start_at |> local_date(timezone) |> long_date()

  @doc """
  How long something lasts: "45 min", "2 hr", "1 hr 30 min". Takes a number of
  minutes or a start and end; nothing (`nil`) for an empty or inverted span.
  """
  @spec duration(integer()) :: String.t() | nil
  def duration(minutes) when minutes <= 0, do: nil

  def duration(minutes) when minutes < 60,
    do: dgettext("dashboard_common", "%{minutes} min", minutes: minutes)

  def duration(minutes) do
    case {div(minutes, 60), rem(minutes, 60)} do
      {hours, 0} ->
        dgettext("dashboard_common", "%{hours} hr", hours: hours)

      {hours, mins} ->
        dgettext("dashboard_common", "%{hours} hr %{mins} min", hours: hours, mins: mins)
    end
  end

  @spec duration(DateTime.t(), DateTime.t()) :: String.t() | nil
  def duration(start_at, end_at), do: duration(DateTime.diff(end_at, start_at, :minute))

  @doc "The organiser's local date for a UTC instant."
  @spec local_date(DateTime.t(), String.t()) :: Date.t()
  def local_date(datetime, timezone), do: datetime |> local(timezone) |> DateTime.to_date()

  defp dated_clock(local, time_format),
    do:
      "#{LocaleFormat.format_short_date(local, locale())}, #{TimeFormat.format(local, time_format)}"

  defp keep_together(text), do: String.replace(text, " ", @nbsp)

  defp local(datetime, timezone), do: DateTimeUtils.convert_to_timezone(datetime, timezone)

  defp locale, do: Gettext.get_locale(TymeslotWeb.Gettext)
end
