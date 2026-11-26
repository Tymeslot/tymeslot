defmodule TymeslotWeb.Dashboard.Calendar.PeriodLabels do
  @moduledoc """
  The words for a calendar period: the toolbar's title (`title/4`), the
  phone header's shorter one (`short_title/4`, shown as `compact_title/4`), what previous and next step
  by (`step_label/2`) and each view's name (`view_label/1`). Shared by the
  toolbar and the phone header, so the two never disagree.

  Strings the toolbar already had keep their `dashboard_calendar` msgids
  ("Month", "Agenda", "Previous month", "Next month"); only the new ones are
  in `dashboard_calendar_views`.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Helpers.LocaleFormat

  @doc """
  The period's title: a day's full date, a month's name, where an agenda
  starts, else the month (or months) the days fall in.
  """
  @spec title(Period.view(), Date.t(), [Date.t()], String.t()) :: String.t()
  def title(:day, date, _days, locale), do: LocaleFormat.format_weekday_date(date, locale)

  def title(:month, date, _days, locale),
    do: LocaleFormat.format_month_year(date.month, date.year, locale)

  def title(:agenda, date, _days, locale),
    do: from(LocaleFormat.format_short_weekday_date(date, locale), locale)

  def title(_view, _date, days, locale) do
    first = List.first(days)
    last = List.last(days)

    cond do
      {first.year, first.month} == {last.year, last.month} ->
        LocaleFormat.format_month_year(first.month, first.year, locale)

      first.year == last.year ->
        range_title(
          LocaleFormat.format_month_name(first.month, locale, :short),
          LocaleFormat.format_month_year(last.month, last.year, locale)
        )

      true ->
        range_title(
          LocaleFormat.format_month_year(first.month, first.year, locale),
          LocaleFormat.format_month_year(last.month, last.year, locale)
        )
    end
  end

  @doc """
  The phone header's title, short enough for its 44px row: "Mon 19 Oct",
  "19 to 21 Oct", "30 Oct to 1 Nov", "Oct 2026", "From 19 Oct".
  """
  @spec short_title(Period.view(), Date.t(), [Date.t()], String.t()) :: String.t()
  def short_title(:day, date, _days, locale),
    do: LocaleFormat.format_short_weekday_date(date, locale)

  def short_title(:month, date, _days, locale),
    do:
      LocaleFormat.capitalize_first(
        "#{LocaleFormat.format_month_name(date.month, locale, :short)} #{date.year}"
      )

  def short_title(:agenda, date, _days, locale),
    do: from(LocaleFormat.format_short_date(date, locale), locale)

  def short_title(_view, _date, days, locale) do
    {first, last} = day_range(days, locale)
    dgettext("dashboard_calendar_views", "%{first} to %{last}", first: first, last: last)
  end

  @doc """
  What the phone header shows, on one line at 360px: `short_title/4` with
  a range's words given way to a dash ("19 – 21 Oct", "30 Oct – 1 Nov").
  The header's accessible name keeps `short_title/4`.
  """
  @spec compact_title(Period.view(), Date.t(), [Date.t()], String.t()) :: String.t()
  def compact_title(view, date, days, locale) when view in [:day, :month, :agenda],
    do: short_title(view, date, days, locale)

  def compact_title(_view, _date, days, locale) do
    {first, last} = day_range(days, locale)
    range_title(first, last)
  end

  @doc "The accessible name of the previous (`:previous`) or next (`:next`) control."
  @spec step_label(Period.view(), :previous | :next) :: String.t()
  def step_label(:day, :previous), do: dgettext("dashboard_calendar", "Previous day")
  def step_label(:day, :next), do: dgettext("dashboard_calendar", "Next day")

  def step_label(:three_day, :previous),
    do: dgettext("dashboard_calendar", "Previous three days")

  def step_label(:three_day, :next), do: dgettext("dashboard_calendar", "Next three days")
  def step_label(:week, :previous), do: dgettext("dashboard_calendar", "Previous week")
  def step_label(:week, :next), do: dgettext("dashboard_calendar", "Next week")
  def step_label(:month, :previous), do: dgettext("dashboard_calendar", "Previous month")
  def step_label(:month, :next), do: dgettext("dashboard_calendar", "Next month")
  def step_label(:agenda, :previous), do: dgettext("dashboard_calendar_views", "Earlier")
  def step_label(:agenda, :next), do: dgettext("dashboard_calendar_views", "Later")

  @doc "A view's name, as the view switch and the phone's tabs show it."
  @spec view_label(Period.view()) :: String.t()
  def view_label(:day), do: dgettext("dashboard_calendar", "Day")
  def view_label(:three_day), do: dgettext("dashboard_calendar", "3 days")
  def view_label(:week), do: dgettext("dashboard_calendar", "Week")
  def view_label(:month), do: dgettext("dashboard_calendar", "Month")
  def view_label(:agenda), do: dgettext("dashboard_calendar", "Agenda")

  # The first and last day, the first without its month when both share it.
  defp day_range(days, locale) do
    first = List.first(days)
    last = List.last(days)

    first_text =
      if {first.year, first.month} == {last.year, last.month},
        do: LocaleFormat.format_day_of_month(first.day, locale),
        else: LocaleFormat.format_short_date(first, locale)

    {first_text, LocaleFormat.format_short_date(last, locale)}
  end

  # Italian has no word for "from" here: the article merged with "da" opens
  # the title ("Dall'8 ott"), so the result is capitalised.
  defp from(date, locale) do
    from_date = LocaleFormat.with_article(date, :da, locale)

    LocaleFormat.capitalize_first(
      dgettext("dashboard_calendar_views", "From %{from_date}", from_date: from_date)
    )
  end

  defp range_title(first, last),
    do: dgettext("dashboard_calendar", "%{first} – %{last}", first: first, last: last)
end
