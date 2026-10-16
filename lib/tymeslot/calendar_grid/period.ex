defmodule Tymeslot.CalendarGrid.Period do
  @moduledoc """
  The days a calendar view shows, and how it steps from one period to the next.

  Pure date arithmetic. The calendar surface loads events for `window/4` (the
  period plus one period either side), and `assets/js/calendar/time.js`
  mirrors `days/4` and `shift/3` so the browser can draw a neighbouring
  period from events it already holds. The two must agree; their tests pin
  the same cases.
  """

  @type view :: :day | :three_day | :week
  @type week_start :: :monday | :sunday

  @views %{"day" => :day, "three_day" => :three_day, "week" => :week}
  @steps %{day: 1, three_day: 3, week: 7}

  @doc "The views the surface draws, in toolbar order."
  @spec views() :: [view()]
  def views, do: [:day, :three_day, :week]

  @doc "Reads a view from a URL parameter, or `default` when it names none."
  @spec parse_view(term(), view()) :: view()
  def parse_view(value, default) when is_binary(value), do: Map.get(@views, value, default)
  def parse_view(_value, default), do: default

  @doc """
  The view to open when the URL names none: the stored default when the
  surface draws it, otherwise the week (month and agenda arrive later).
  """
  @spec default_view(String.t() | nil) :: view()
  def default_view("day"), do: :day
  def default_view(_stored), do: :week

  @doc """
  Reads an ISO date from a URL parameter, or `fallback`. Years outside
  1900 to 2200 fall back too, so stepping and window maths stay in range.
  """
  @spec parse_date(term(), Date.t()) :: Date.t()
  def parse_date(value, fallback) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, %Date{year: year} = date} when year in 1900..2200 -> date
      _invalid_or_out_of_range -> fallback
    end
  end

  def parse_date(_value, fallback), do: fallback

  @doc "The stored `week_start_day` as the atom `Date.beginning_of_week/2` takes."
  @spec week_start(String.t() | nil) :: week_start()
  def week_start("sunday"), do: :sunday
  def week_start(_stored), do: :monday

  @doc "The days `view` shows around `date`."
  @spec days(view(), Date.t(), week_start(), boolean()) :: [Date.t()]
  def days(:day, date, _week_start, _weekends?), do: [date]
  def days(:three_day, date, _week_start, _weekends?), do: Enum.map(0..2, &Date.add(date, &1))

  def days(:week, date, week_start, weekends?) do
    first = Date.beginning_of_week(date, week_start)
    days = Enum.map(0..6, &Date.add(first, &1))

    if weekends?, do: days, else: Enum.reject(days, &(Date.day_of_week(&1) in [6, 7]))
  end

  @doc "The anchor date one period before (`-1`) or after (`1`) `date`."
  @spec shift(view(), Date.t(), -1 | 1) :: Date.t()
  def shift(view, date, direction), do: Date.add(date, direction * Map.fetch!(@steps, view))

  @doc """
  The days the surface loads events for: from the first day of the previous
  period to the last day of the next, contiguous even when weekends are
  hidden, so a step either way renders from data already in the browser.
  """
  @spec window(view(), Date.t(), week_start(), boolean()) :: Date.Range.t()
  def window(view, date, week_start, _weekends?) do
    first = view |> days(shift(view, date, -1), week_start, true) |> List.first()
    last = view |> days(shift(view, date, 1), week_start, true) |> List.last()

    Date.range(first, last)
  end

  @doc "Six weeks of seven days covering `date`'s month, for a mini-month."
  @spec month_matrix(Date.t(), week_start()) :: [[Date.t()]]
  def month_matrix(date, week_start) do
    first = date |> Date.beginning_of_month() |> Date.beginning_of_week(week_start)

    first |> Date.range(Date.add(first, 41)) |> Enum.chunk_every(7)
  end
end
