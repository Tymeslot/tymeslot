defmodule Tymeslot.BookingSeries.Rule do
  @moduledoc """
  How a recurring series' rhythm reads: "Every week on Thursday at 17:00",
  "Every 2 weeks on Thursday at 17:00", "Every month on the second Thursday
  at 17:00".

  Shared by everything that names the rhythm: the series emails, and later
  the booking page, the series page, the type editor and the dashboard. The
  phrases live in the `booking_series` domain so all of them can use it.

  Given the series' (or the type's) first start, the phrase names the day
  and time of that start, read in the zone the `DateTime` is in: the caller
  shifts it into the reader's timezone first. Without one (a meeting type,
  before anyone has picked a first session) it names the rhythm alone:
  "Every week", "Every 2 weeks", "Every month on the same weekday".

  A monthly series keeps the weekday ordinal of its first date
  (`Tymeslot.BookingSeries.Dates`): the 2nd Thursday stays the 2nd Thursday,
  and a fifth weekday falls back to the month's last such weekday, so it
  reads as "on the last Friday".

  A flexible series has no rhythm (its sessions were picked at different
  times), so it has no phrase: `nil`, as for a type that offers no series.
  The caller names the session count instead, which it already knows.

  Each position (the second Thursday) and each weekday (on Thursday) is one
  translated phrase rather than an ordinal or a name glued into a sentence:
  in several of the app's languages the ordinal agrees with the weekday's
  gender and the weekday takes a case after its preposition (Polish "w drugi
  czwartek", "w drugą środę").
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  @weekdays [
    {1, "Monday"},
    {2, "Tuesday"},
    {3, "Wednesday"},
    {4, "Thursday"},
    {5, "Friday"},
    {6, "Saturday"},
    {7, "Sunday"}
  ]

  @ordinals [{1, "first"}, {2, "second"}, {3, "third"}, {4, "fourth"}, {:last, "last"}]

  @doc """
  The rhythm of `subject` (a series, or a meeting type) in `locale`, or nil
  when it has none.

  Options:

    * `:first_start` - the first session's start, in the zone the phrase is
      read in. With it the phrase names the day and time; without it, the
      rhythm alone.
    * `:time_format` - `"12h"` or `"24h"`, a clock the reader chose (the
      organiser's). Without it the locale's clock is used.
  """
  @spec describe(SeriesSchema.t() | MeetingTypeSchema.t(), String.t(), keyword()) ::
          String.t() | nil
  def describe(subject, locale, opts \\ []) do
    case rhythm(subject) do
      nil ->
        nil

      {frequency, interval} ->
        Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
          phrase(
            frequency,
            interval,
            Keyword.get(opts, :first_start),
            locale,
            Keyword.delete(opts, :ordinal)
          )
        end)
    end
  end

  @doc """
  The rhythm of `series` as its sessions now stand, each start read in
  `timezone`: the full phrase while every session keeps the series' day and
  time, the rhythm alone once one was moved, since a moved session (the
  first one included) would otherwise put its own day and time on the whole
  series. Nil for a flexible series. `opts` as for `describe/3`.

  A monthly series that began on a fifth weekday is held on the month's last
  one (`Tymeslot.BookingSeries.Dates`), so a session on a fourth weekday that
  is its month's last still keeps the rhythm: "on the last Friday" covers
  Friday 30 January and Friday 27 February alike. The series' first start
  (`first_start_at`, or the earliest of `starts` without one) says whether
  it is held on the last weekday.
  """
  @spec describe_sessions(SeriesSchema.t(), [DateTime.t()], String.t(), String.t(), keyword()) ::
          String.t() | nil
  def describe_sessions(%SeriesSchema{} = series, starts, locale, timezone, opts \\ []) do
    locals = Enum.map(starts, &local(&1, timezone))
    held_last? = held_on_last?(series.first_start_at, locals, timezone)

    case rhythm(series) do
      nil ->
        nil

      {frequency, interval} ->
        keys = locals |> Enum.map(&session_key(frequency, &1, held_last?)) |> Enum.uniq()

        Gettext.with_locale(TymeslotWeb.Gettext, locale, fn ->
          case keys do
            [key] ->
              opts = Keyword.put(opts, :ordinal, key[:ordinal])
              phrase(frequency, interval, hd(locals), locale, opts)

            _none_or_moved ->
              phrase(frequency, interval, nil, locale, opts)
          end
        end)
    end
  end

  defp local(start, timezone) do
    {local, _zone} = DateTimeUtils.shift_or_utc(start, timezone)
    local
  end

  # What the phrase names of one session: the time, the weekday for a weekly
  # or monthly series, and the weekday's ordinal for a monthly one.
  defp session_key(:daily, local, _held_last?), do: [time: DateTime.to_time(local)]

  defp session_key(:weekly, local, _held_last?),
    do: [time: DateTime.to_time(local), weekday: weekday(local)]

  defp session_key(:monthly, local, held_last?),
    do: [
      time: DateTime.to_time(local),
      weekday: weekday(local),
      ordinal: session_ordinal(local, held_last?)
    ]

  defp weekday(local), do: local |> DateTime.to_date() |> Date.day_of_week()

  # Whether the series is held on its month's last weekday: it began on a
  # fifth one.
  defp held_on_last?(%DateTime{} = first_start, _locals, timezone),
    do: ordinal(DateTime.to_date(local(first_start, timezone))) == :last

  defp held_on_last?(nil, [], _timezone), do: false

  defp held_on_last?(nil, locals, _timezone),
    do: ordinal(DateTime.to_date(Enum.min(locals, DateTime))) == :last

  # A session's ordinal as the series reads it: the month's last weekday
  # counts as "last" in a series held on the last weekday.
  defp session_ordinal(local, held_last?) do
    date = DateTime.to_date(local)

    if held_last? and last_weekday_of_month?(date),
      do: :last,
      else: ordinal(date)
  end

  defp last_weekday_of_month?(date), do: Date.add(date, 7).month != date.month

  defp rhythm(%SeriesSchema{mode: :recurring, frequency: frequency, interval: interval})
       when frequency in [:daily, :weekly, :monthly],
       do: {frequency, interval || 1}

  defp rhythm(%MeetingTypeSchema{
         series_mode: :recurring,
         series_frequency: frequency,
         series_interval: interval
       })
       when frequency in [:daily, :weekly, :monthly],
       do: {frequency, interval || 1}

  defp rhythm(_subject), do: nil

  # The rhythm alone, before there is a first session.
  defp phrase(:monthly, 1, nil, _locale, _opts),
    do: dgettext("booking_series", "Every month on the same weekday")

  defp phrase(:monthly, interval, nil, _locale, _opts),
    do:
      dngettext(
        "booking_series",
        "Every %{count} month on the same weekday",
        "Every %{count} months on the same weekday",
        interval
      )

  defp phrase(frequency, interval, nil, _locale, _opts), do: every(frequency, interval)

  defp phrase(:daily, interval, %DateTime{} = first_start, locale, opts) do
    dgettext("booking_series", "%{frequency} at %{time}",
      frequency: every(:daily, interval),
      time: time(first_start, locale, opts)
    )
  end

  defp phrase(frequency, interval, %DateTime{} = first_start, locale, opts) do
    dgettext("booking_series", "%{frequency} %{day} at %{time}",
      frequency: every(frequency, interval),
      day: day(frequency, DateTime.to_date(first_start), opts[:ordinal]),
      time: time(first_start, locale, opts)
    )
  end

  # "Every week" for an interval of one, never the plural form with a count
  # of one: in Czech, Polish and Ukrainian the singular form also serves 21,
  # 31 and so on, so it has to carry the number.
  defp every(:daily, 1), do: dgettext("booking_series", "Every day")
  defp every(:weekly, 1), do: dgettext("booking_series", "Every week")
  defp every(:monthly, 1), do: dgettext("booking_series", "Every month")

  defp every(:daily, interval),
    do: dngettext("booking_series", "Every %{count} day", "Every %{count} days", interval)

  defp every(:weekly, interval),
    do: dngettext("booking_series", "Every %{count} week", "Every %{count} weeks", interval)

  defp every(:monthly, interval),
    do: dngettext("booking_series", "Every %{count} month", "Every %{count} months", interval)

  # `ordinal` overrides the date's own (`describe_sessions/5`).
  defp day(:weekly, date, _ordinal), do: on_weekday(Date.day_of_week(date))

  defp day(:monthly, date, ordinal),
    do: on_position(ordinal || ordinal(date), Date.day_of_week(date))

  # The weekday's ordinal in its month, as `Dates` steps it: a fifth weekday
  # is held as the month's last one.
  defp ordinal(date) do
    case div(date.day - 1, 7) + 1 do
      5 -> :last
      ordinal -> ordinal
    end
  end

  for {number, name} <- @weekdays do
    defp on_weekday(unquote(number)),
      do: dgettext("booking_series", unquote("on #{name}"))

    for {ordinal, ordinal_word} <- @ordinals do
      defp on_position(unquote(ordinal), unquote(number)),
        do: dgettext("booking_series", unquote("on the #{ordinal_word} #{name}"))
    end
  end

  defp time(first_start, locale, opts) do
    time = DateTime.to_time(first_start)

    case Keyword.get(opts, :time_format) do
      nil -> LocaleFormat.format_time(time, locale)
      time_format -> TimeFormat.format(time, time_format)
    end
  end
end
