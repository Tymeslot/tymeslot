defmodule Tymeslot.CalendarGrid.Period do
  @moduledoc """
  The days a calendar view shows, and how it steps from one period to the next.

  Pure date arithmetic. The calendar surface loads events for `window/4` (the
  period plus one period either side; a day loads its whole week either
  side, so the phone's week strip has every day's events), and
  `assets/js/calendar/time.js` mirrors `days/4` and `shift/3` so the browser
  can draw a neighbouring period from events it already holds. The two must
  agree; their tests pin the same cases.

  Day, three days and week are time grids (`time_grid?/1`). A month is the
  six weeks of `month_matrix/2`, always seven columns, and steps by a
  calendar month with the day clamped (31 January to 28 February). An
  agenda lists `agenda_days/0` days from its date and grows as it scrolls,
  up to `agenda_max_days/0` (see `TymeslotWeb.Dashboard.Calendar.AgendaLoader`).
  """

  @type view :: :day | :three_day | :week | :month | :agenda
  @type viewport :: :phone | :wide
  @type week_start :: :monday | :sunday

  @views %{
    "day" => :day,
    "three_day" => :three_day,
    "week" => :week,
    "month" => :month,
    "agenda" => :agenda
  }
  @steps %{day: 1, three_day: 3, week: 7}
  @time_grid [:day, :three_day, :week]
  @agenda_days 28
  @agenda_max_days 168

  @doc "The views the surface draws, in the desktop toolbar's order."
  @spec views() :: [view()]
  def views, do: [:day, :three_day, :week, :month, :agenda]

  @doc "The views a phone offers, in the order of its bottom tabs."
  @spec phone_views() :: [view()]
  def phone_views, do: [:agenda, :day, :three_day, :month]

  @doc "Whether `view` draws the time grid (hours down, days across)."
  @spec time_grid?(view()) :: boolean()
  def time_grid?(view), do: view in @time_grid

  @doc """
  The view shown for `view` on a viewport: a week on a phone shows three
  days (seven columns do not fit); every other view is itself. The URL and
  the stored default keep the view asked for.
  """
  @spec for_viewport(view(), viewport()) :: view()
  def for_viewport(:week, :phone), do: :three_day
  def for_viewport(view, _viewport), do: view

  @doc "The days an agenda loads at a time, and the step of its previous and next."
  @spec agenda_days() :: pos_integer()
  def agenda_days, do: @agenda_days

  @doc "The furthest an agenda extends from its date before \"Show later\" moves the date on."
  @spec agenda_max_days() :: pos_integer()
  def agenda_max_days, do: @agenda_max_days

  @doc "Reads a view from a URL parameter, or `default` when it names none."
  @spec parse_view(term(), view()) :: view()
  def parse_view(value, default) when is_binary(value), do: Map.get(@views, value, default)
  def parse_view(_value, default), do: default

  @doc """
  The view to open when the URL names none: the stored default (day, week,
  month or agenda), else the week. A phone shows a week as three days
  (`for_viewport/2`) without the stored value changing.
  """
  @spec default_view(String.t() | nil) :: :day | :week | :month | :agenda
  def default_view("day"), do: :day
  def default_view("month"), do: :month
  def default_view("agenda"), do: :agenda
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

  @doc """
  The days `view` shows around `date`. A month always shows seven columns;
  hidden weekends apply to the week alone.
  """
  @spec days(view(), Date.t(), week_start(), boolean()) :: [Date.t()]
  def days(:day, date, _week_start, _weekends?), do: [date]
  def days(:three_day, date, _week_start, _weekends?), do: Enum.map(0..2, &Date.add(date, &1))

  def days(:week, date, week_start, weekends?) do
    first = Date.beginning_of_week(date, week_start)
    days = Enum.map(0..6, &Date.add(first, &1))

    if weekends?, do: days, else: Enum.reject(days, &(Date.day_of_week(&1) in [6, 7]))
  end

  def days(:month, date, week_start, _weekends?),
    do: date |> month_matrix(week_start) |> List.flatten()

  def days(:agenda, date, _week_start, _weekends?),
    do: Enum.map(0..(@agenda_days - 1), &Date.add(date, &1))

  @doc """
  The anchor date one period before (`-1`) or after (`1`) `date`. A month
  keeps the day of the month where the target month has it, else its last
  day, as `Date.shift/2` does.
  """
  @spec shift(view(), Date.t(), -1 | 1) :: Date.t()
  def shift(:month, date, direction), do: Date.shift(date, month: direction)
  def shift(:agenda, date, direction), do: Date.add(date, direction * @agenda_days)
  def shift(view, date, direction), do: Date.add(date, direction * Map.fetch!(@steps, view))

  @doc """
  The date to open another view at, switching from `view` at `date`. Every
  view shares one date, but a week and a month show the period around it
  while the other views start from it, and stepping by a week or a month
  can leave the date part-way through. A week or a month therefore hands
  over `today` when today is one of its days (a month's own days, not the
  neighbours its grid shows), else its first day; the other views keep the
  date. `viewSwitchAnchor` in `assets/js/calendar/time.js` mirrors it.
  """
  @spec view_switch_anchor(view(), Date.t(), Date.t(), week_start()) :: Date.t()
  def view_switch_anchor(:week, date, today, week_start) do
    first = Date.beginning_of_week(date, week_start)
    today_or_first(Date.range(first, Date.add(first, 6)), today)
  end

  def view_switch_anchor(:month, date, today, _week_start),
    do: today_or_first(Date.range(Date.beginning_of_month(date), Date.end_of_month(date)), today)

  def view_switch_anchor(_view, date, _today, _week_start), do: date

  defp today_or_first(%Date.Range{first: first} = period, today),
    do: if(today in period, do: today, else: first)

  @doc """
  The days the surface loads events for: from the first day of the previous
  period to the last day of the next, contiguous even when weekends are
  hidden, so a step either way renders from data already in the browser. A
  day loads its week's window, so the phone's week strip can show every
  day's events and a switch between day and week needs no query.
  """
  @spec window(view(), Date.t(), week_start(), boolean()) :: Date.Range.t()
  def window(:day, date, week_start, weekends?), do: window(:week, date, week_start, weekends?)

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

  @doc """
  The ISO week a row of days belongs to: the week of its Monday, or of its
  first day when it has none (a day, three days). A row that starts on a
  Sunday is numbered by the Monday after it, the week six of its seven days
  are in. `assets/js/calendar/week_numbers.js` (`rowWeek`) mirrors it.
  """
  @spec week_number([Date.t(), ...]) :: 1..53
  def week_number([first | _rest] = days) do
    day = Enum.find(days, first, &(Date.day_of_week(&1) == 1))
    {_year, week} = :calendar.iso_week_number(Date.to_erl(day))
    week
  end
end
