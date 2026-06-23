defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers do
  @moduledoc "Helpers that read user preferences and produce display-related values for the calendar grid."

  import Phoenix.Component, only: [assign: 3]

  @spec week_start(Date.t(), map()) :: Date.t()
  def week_start(date, assigns), do: Date.beginning_of_week(date, week_start_atom(assigns))

  @spec col_count(map()) :: integer()
  def col_count(%{view: :week} = assigns), do: if(show_weekends?(assigns), do: 7, else: 5)
  def col_count(%{view: :three_day}), do: 3
  def col_count(%{view: :day}), do: 1
  def col_count(%{view: :month}), do: 7
  def col_count(%{view: :agenda}), do: 1

  @spec day_header_class(Date.t()) :: String.t()
  def day_header_class(day) do
    if Date.compare(day, Date.utc_today()) == :eq do
      "font-bold text-turquoise-600"
    else
      "text-tymeslot-600"
    end
  end

  @spec period_label(map()) :: String.t()
  def period_label(%{view: :week, date: date} = assigns) do
    ws = week_start(date, assigns)
    we = Date.add(ws, 6)
    range_label(ws, we)
  end

  def period_label(%{view: :three_day, date: date}) do
    range_label(date, Date.add(date, 2))
  end

  def period_label(%{view: :day, date: date}) do
    Calendar.strftime(date, "%A, %B %-d, %Y")
  end

  def period_label(%{view: :month, date: date}) do
    Calendar.strftime(date, "%B %Y")
  end

  def period_label(%{view: :agenda}), do: "Next 30 days"

  defp range_label(start_date, end_date) do
    start_str = Calendar.strftime(start_date, "%B %-d")

    end_str =
      if start_date.month == end_date.month do
        Calendar.strftime(end_date, "%-d, %Y")
      else
        Calendar.strftime(end_date, "%B %-d, %Y")
      end

    "#{start_str} \u2013 #{end_str}"
  end

  @spec view_label(atom()) :: String.t()
  def view_label(:day), do: "Day"
  def view_label(:three_day), do: "3 Days"
  def view_label(:week), do: "Week"
  def view_label(:month), do: "Month"
  def view_label(:agenda), do: "Agenda"

  @spec navigate_month(Date.t(), integer()) :: Date.t()
  def navigate_month(date, delta) do
    Date.shift(Date.new!(date.year, date.month, 1), month: delta)
  end

  @spec month_cell_class(Date.t(), map()) :: String.t()
  def month_cell_class(day, assigns) do
    if day.month != assigns.date.month, do: "bg-tymeslot-50", else: "bg-white"
  end

  @spec week_start_atom(map()) :: :monday | :sunday
  def week_start_atom(%{preferences: %{week_start_day: "sunday"}}), do: :sunday
  def week_start_atom(_assigns), do: :monday

  @spec show_weekends?(map()) :: boolean()
  def show_weekends?(%{preferences: %{show_weekends: false}}), do: false
  def show_weekends?(_assigns), do: true

  @spec show_week_numbers?(map()) :: boolean()
  def show_week_numbers?(%{preferences: %{show_week_numbers: true}}), do: true
  def show_week_numbers?(_assigns), do: false

  @spec time_format(map()) :: String.t()
  def time_format(%{preferences: %{time_format: fmt}}), do: fmt
  def time_format(_assigns), do: "12h"

  @valid_views %{
    "week" => :week,
    "three_day" => :three_day,
    "day" => :day,
    "month" => :month,
    "agenda" => :agenda
  }

  @spec safe_view_atom(String.t()) :: :week | :three_day | :day | :month | :agenda
  def safe_view_atom(view) when is_binary(view), do: Map.get(@valid_views, view, :week)
  def safe_view_atom(_view), do: :week

  @spec assign_view_from_preferences(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_view_from_preferences(socket) do
    assign(socket, :view, safe_view_atom(socket.assigns.preferences.default_view))
  end

  @spec week_number(Date.t()) :: integer()
  def week_number(date) do
    {_year, week} = :calendar.iso_week_number(Date.to_erl(date))
    week
  end

  @spec day_name_headers(map()) :: [String.t()]
  def day_name_headers(assigns) do
    monday_start = ~w(Mon Tue Wed Thu Fri Sat Sun)
    sunday_start = ~w(Sun Mon Tue Wed Thu Fri Sat)

    if week_start_atom(assigns) == :sunday, do: sunday_start, else: monday_start
  end
end
