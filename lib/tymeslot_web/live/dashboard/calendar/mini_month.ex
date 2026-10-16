defmodule TymeslotWeb.Dashboard.Calendar.MiniMonth do
  @moduledoc """
  A month of day buttons with the visible range marked, used in the rail and
  in the period title's date picker. A day click navigates like every other
  control (`Navigation.js/2`), keeping the current view.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Helpers.LocaleFormat

  attr :id, :string, required: true
  attr :cursor, :any, required: true, doc: "the first of the month shown"
  attr :view, :atom, required: true
  attr :days, :list, required: true, doc: "the days the grid shows, marked"
  attr :today, :any, required: true
  attr :week_start, :atom, required: true
  attr :locale, :string, required: true
  attr :target, :any, required: true

  @spec mini_month(map()) :: Phoenix.LiveView.Rendered.t()
  def mini_month(assigns) do
    assigns =
      assign(assigns,
        weeks: Period.month_matrix(assigns.cursor, assigns.week_start),
        initials: initials(assigns.locale, assigns.week_start)
      )

    ~H"""
    <div id={@id} class="select-none">
      <div class="mb-1 flex items-center justify-between">
        <span class="text-token-sm font-semibold text-tymeslot-800">
          {LocaleFormat.format_month_year(@cursor.month, @cursor.year, @locale)}
        </span>
        <div class="flex items-center">
          <.icon_button
            icon="hero-chevron-left-mini"
            size={:sm}
            label={dgettext("dashboard_calendar", "Previous month")}
            phx-click={JS.push("calendar:mini_shift", value: %{dir: -1}, target: @target)}
          />
          <.icon_button
            icon="hero-chevron-right-mini"
            size={:sm}
            label={dgettext("dashboard_calendar", "Next month")}
            phx-click={JS.push("calendar:mini_shift", value: %{dir: 1}, target: @target)}
          />
        </div>
      </div>
      <div
        class="grid grid-cols-7 text-center text-token-2xs font-semibold text-tymeslot-500"
        aria-hidden="true"
      >
        <span :for={initial <- @initials}>{initial}</span>
      </div>
      <div :for={week <- @weeks} class="grid grid-cols-7">
        <button
          :for={day <- week}
          type="button"
          phx-click={Navigation.js(@view, day)}
          aria-label={LocaleFormat.format_weekday_date(day, @locale)}
          aria-current={if(day == @today, do: "date")}
          aria-pressed={to_string(day in @days)}
          class={day_class(day, @cursor, @days, @today)}
        >
          {day.day}
        </button>
      </div>
    </div>
    """
  end

  defp day_class(day, cursor, days, today) do
    [
      "h-7 rounded-token-md text-token-xs tabular-nums focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400",
      cond do
        day == today -> "bg-turquoise-700 font-semibold text-white"
        day in days -> "bg-turquoise-50 font-semibold text-turquoise-800"
        day.month != cursor.month -> "text-tymeslot-500 hover:bg-tymeslot-50"
        true -> "text-tymeslot-700 hover:bg-tymeslot-50"
      end
    ]
  end

  defp initials(locale, week_start) do
    [sunday | monday_to_saturday] = LocaleFormat.get_weekday_names(locale, :narrow)

    if week_start == :sunday,
      do: [sunday | monday_to_saturday],
      else: monday_to_saturday ++ [sunday]
  end
end
