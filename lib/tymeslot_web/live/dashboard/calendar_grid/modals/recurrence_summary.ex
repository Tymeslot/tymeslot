defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceSummary do
  @moduledoc """
  How a repeat pattern reads, for the grid's repeat editor and the event
  details: "Repeats monthly on the second Tuesday, 6 times".

  A position (the second Tuesday, the last weekday) is one translated
  phrase, never an ordinal glued to a weekday: the ordinal agrees with the
  weekday's gender in several of the app's languages (Polish "w drugi
  wtorek", "w drugą środę"). Each month likewise has its own phrases, for
  the case its name takes after a day ("13 października") or a position.

  Rendered in the process's Gettext locale, the end date included, so it is
  called from the LiveView process rather than from a task.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern
  alias TymeslotWeb.Helpers.LocaleFormat

  @ordinals [{1, "first"}, {2, "second"}, {3, "third"}, {4, "fourth"}, {-1, "last"}]
  @kinds [
    {:mo, "Monday"},
    {:tu, "Tuesday"},
    {:we, "Wednesday"},
    {:th, "Thursday"},
    {:fr, "Friday"},
    {:sa, "Saturday"},
    {:su, "Sunday"},
    {:day, "day"},
    {:weekday, "weekday"},
    {:weekend_day, "weekend day"}
  ]
  @weekday_numbers %{mo: 1, tu: 2, we: 3, th: 4, fr: 5, sa: 6, su: 7}
  @months ~w(January February March April May June July August September October November December)

  @doc """
  The summary of `pattern` (see `Pattern`) for a series starting on
  `start_date`, `:custom` for a rule the editor cannot build, or nil for no
  rule.
  """
  @spec summary(Pattern.t() | :custom | nil, Date.t()) :: String.t() | nil
  def summary(nil, _start_date), do: nil

  def summary(:custom, _start_date),
    do: dgettext("dashboard_calendar_repeat", "Repeats on a custom pattern")

  def summary(%{freq: freq} = pattern, start_date) do
    [
      base_phrase(freq, Map.get(pattern, :interval, 1)),
      qualifier(pattern, start_date),
      end_phrase(pattern)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  @doc """
  The phrase for a monthly or yearly `on` (see `Pattern`), for a series
  starting on `start_date`: "on day 13", "on the second Tuesday", "on 13
  October", "on the second Tuesday of October".
  """
  @spec on_phrase(Pattern.on(), :monthly | :yearly, Date.t()) :: String.t()
  def on_phrase(:day, :monthly, start_date),
    do: dgettext("dashboard_calendar_repeat", "on day %{day}", day: day_number(start_date.day))

  def on_phrase(:day, :yearly, start_date), do: on_date(start_date.month, start_date.day)

  def on_phrase(position, :monthly, _start_date), do: position_phrase(position)

  def on_phrase(position, :yearly, start_date),
    do: position_phrase(position) <> " " <> of_month(start_date.month)

  defp qualifier(%{freq: :weekly, by_day: [_first | _rest] = days}, _start_date) do
    dgettext("dashboard_calendar_repeat", "on %{days}",
      days: Enum.map_join(days, ", ", &weekday_label/1)
    )
  end

  defp qualifier(%{freq: freq} = pattern, start_date) when freq in [:monthly, :yearly],
    do: on_phrase(Map.get(pattern, :on, :day), freq, start_date)

  defp qualifier(_pattern, _start_date), do: nil

  # A first to fourth day of the month is a day of the month ("on day 2"),
  # so of the plain days only the last is a position (`Pattern.choices/1`).
  for {ordinal, ordinal_word} <- @ordinals,
      {kind, kind_word} <- @kinds,
      kind != :day or ordinal == -1 do
    defp position_phrase({unquote(ordinal), unquote(kind)}),
      do: dgettext("dashboard_calendar_repeat", unquote("on the #{ordinal_word} #{kind_word}"))
  end

  for {name, month} <- Enum.with_index(@months, 1) do
    defp on_date(unquote(month), day),
      do:
        dgettext("dashboard_calendar_repeat", unquote("on %{day} #{name}"), day: day_number(day))

    defp of_month(unquote(month)),
      do: dgettext("dashboard_calendar_repeat", unquote("of #{name}"))
  end

  defp base_phrase(freq, interval) when interval > 1, do: interval_phrase(freq, interval)
  defp base_phrase(freq, _interval), do: freq_adverb_phrase(freq)

  defp interval_phrase(:daily, interval),
    do:
      dngettext(
        "dashboard_calendar_repeat",
        "Repeats every %{count} day",
        "Repeats every %{count} days",
        interval
      )

  defp interval_phrase(:weekly, interval),
    do:
      dngettext(
        "dashboard_calendar_repeat",
        "Repeats every %{count} week",
        "Repeats every %{count} weeks",
        interval
      )

  defp interval_phrase(:monthly, interval),
    do:
      dngettext(
        "dashboard_calendar_repeat",
        "Repeats every %{count} month",
        "Repeats every %{count} months",
        interval
      )

  defp interval_phrase(:yearly, interval),
    do:
      dngettext(
        "dashboard_calendar_repeat",
        "Repeats every %{count} year",
        "Repeats every %{count} years",
        interval
      )

  defp freq_adverb_phrase(:daily), do: dgettext("dashboard_calendar_repeat", "Repeats daily")
  defp freq_adverb_phrase(:weekly), do: dgettext("dashboard_calendar_repeat", "Repeats weekly")
  defp freq_adverb_phrase(:monthly), do: dgettext("dashboard_calendar_repeat", "Repeats monthly")
  defp freq_adverb_phrase(:yearly), do: dgettext("dashboard_calendar_repeat", "Repeats yearly")

  defp end_phrase(%{count: count}) when is_integer(count),
    do:
      dngettext(
        "dashboard_calendar_repeat",
        "for %{count} occurrence",
        "for %{count} occurrences",
        count
      )

  defp end_phrase(%{until: %Date{} = until}) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    month = LocaleFormat.format_month_name(until.month, locale)
    date = LocaleFormat.order_date_parts(day_number(until.day), month, until.year, locale)
    dgettext("dashboard_calendar_repeat", "until %{date}", date: date)
  end

  defp end_phrase(_pattern), do: nil

  defp day_number(day),
    do: LocaleFormat.format_day_of_month(day, Gettext.get_locale(TymeslotWeb.Gettext))

  @doc """
  The short label of a weekday atom (`:mo` .. `:su`) in the process's
  Gettext locale, in the case the locale gives it mid-sentence ("lun." in
  French, "Mo" in German).
  """
  @spec weekday_label(atom()) :: String.t()
  def weekday_label(day) do
    LocaleFormat.format_weekday_name(
      Map.fetch!(@weekday_numbers, day),
      Gettext.get_locale(TymeslotWeb.Gettext),
      :short
    )
  end
end
