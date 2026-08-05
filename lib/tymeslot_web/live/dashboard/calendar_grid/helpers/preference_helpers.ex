defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.PreferenceHelpers do
  @moduledoc "Helpers that read user preferences and produce display-related values for the calendar grid."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Helpers.LocaleFormat

  @spec week_start(Date.t(), map()) :: Date.t()
  def week_start(date, assigns), do: Date.beginning_of_week(date, week_start_atom(assigns))

  @spec col_count(map()) :: integer()
  def col_count(%{view: :week} = assigns), do: if(show_weekends?(assigns), do: 7, else: 5)
  def col_count(%{view: :three_day}), do: 3
  def col_count(%{view: :day}), do: 1
  def col_count(%{view: :month}), do: 7
  def col_count(%{view: :agenda}), do: 1

  @spec day_header_class(Date.t(), String.t()) :: String.t()
  def day_header_class(day, timezone \\ "Etc/UTC") do
    today =
      DateTime.utc_now()
      |> DateTime.shift_zone!(timezone)
      |> DateTime.to_date()

    if Date.compare(day, today) == :eq do
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
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    weekday = LocaleFormat.format_weekday_name(Date.day_of_week(date), locale, :full)
    month = LocaleFormat.format_month_name(date.month, locale)
    "#{weekday}, #{LocaleFormat.order_date_parts(date.day, month, date.year, locale)}"
  end

  def period_label(%{view: :month, date: date}) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    "#{LocaleFormat.format_month_name(date.month, locale)} #{date.year}"
  end

  def period_label(%{view: :agenda, date: date} = assigns) do
    tz = Map.get(assigns, :user_timezone, "Etc/UTC")

    today =
      DateTime.utc_now()
      |> DateTime.shift_zone!(tz)
      |> DateTime.to_date()

    if Date.compare(date, today) == :eq do
      dgettext("dashboard_calendar", "Next 30 days")
    else
      range_label(date, Date.add(date, 30))
    end
  end

  defp range_label(start_date, end_date) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    LocaleFormat.format_date_range(start_date, end_date, locale)
  end

  @spec view_label(atom()) :: String.t()
  def view_label(:day), do: dgettext("dashboard_calendar", "Day")
  def view_label(:three_day), do: dgettext("dashboard_calendar", "3 Days")
  def view_label(:week), do: dgettext("dashboard_calendar", "Week")
  def view_label(:month), do: dgettext("dashboard_calendar", "Month")
  def view_label(:agenda), do: dgettext("dashboard_calendar", "Agenda")

  @spec navigate_month(Date.t(), integer()) :: Date.t()
  def navigate_month(date, delta) do
    Date.shift(Date.new!(date.year, date.month, 1), month: delta)
  end

  @doc """
  6×7 day matrix for the month containing `date`.

  Returns 42 consecutive `Date` structs starting from the first day of the week
  that contains the first of the month (honouring `week_start`), so the grid
  always spans six full weeks. Shared by the month view and the mini-month
  picker so both render the same cells.
  """
  @spec month_matrix(Date.t(), :monday | :sunday) :: [Date.t()]
  def month_matrix(date, week_start) when week_start in [:monday, :sunday] do
    first_of_month = Date.new!(date.year, date.month, 1)
    grid_start = Date.beginning_of_week(first_of_month, week_start)
    Enum.map(0..41, &Date.add(grid_start, &1))
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

  @doc """
  The clock format to render in: the organiser's stored choice, or the preset
  their language implies when they have never set one.

  Accepts either an assigns map (`%{preferences: %{time_format: …}}`) or a bare
  preferences map (`%{time_format: …}`), so view helpers can pass whichever they
  hold without re-deriving the fallback.
  """
  @spec time_format(map()) :: String.t()
  def time_format(%{preferences: %{time_format: stored}}), do: resolve_time_format(stored)
  def time_format(%{time_format: stored}) when is_binary(stored), do: resolve_time_format(stored)
  def time_format(_assigns), do: resolve_time_format(nil)

  defp resolve_time_format(stored),
    do: TimeFormat.resolve(stored, Gettext.get_locale(TymeslotWeb.Gettext))

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
    locale = Gettext.get_locale(TymeslotWeb.Gettext)

    iso_order =
      if week_start_atom(assigns) == :sunday,
        do: [7, 1, 2, 3, 4, 5, 6],
        else: [1, 2, 3, 4, 5, 6, 7]

    Enum.map(iso_order, &LocaleFormat.format_weekday_name(&1, locale, :short))
  end
end
