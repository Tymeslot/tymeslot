defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.MiniMonthPopover do
  @moduledoc """
  Compact month-grid date picker hung off the toolbar period label.

  Renders a 6×7 day matrix for the picker month (`cursor`), with a weekday
  header row honouring `week_start` and optional week numbers. Today and the
  currently-viewed date are highlighted; days outside the picker month are
  dimmed. The header prev/next arrows step the picker month without navigating
  the main grid; clicking a day pushes `navigate_to_day` (which jumps the grid
  and closes the popover).
  """

  use TymeslotWeb, :html

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  attr :open, :boolean, required: true
  attr :view, :atom, required: true, doc: "The active grid view; drives the period label."
  attr :date, :any, required: true, doc: "The currently-viewed grid date (selected/highlighted)."
  attr :cursor, :any, default: nil, doc: "The picker month; defaults to `@date` when nil."
  attr :preferences, :any, default: nil
  attr :user_timezone, :string, required: true
  attr :myself, :any, required: true

  @spec mini_month_popover(map()) :: Phoenix.LiveView.Rendered.t()
  def mini_month_popover(assigns) do
    cursor = assigns.cursor || assigns.date
    week_start = Helpers.week_start_atom(assigns)

    today =
      DateTime.utc_now()
      |> DateTime.shift_zone!(assigns.user_timezone)
      |> DateTime.to_date()

    assigns =
      assigns
      |> assign(:cursor, cursor)
      |> assign(:today, today)
      |> assign(:weeks, Enum.chunk_every(Helpers.month_matrix(cursor, week_start), 7))
      |> assign(:show_week_numbers, Helpers.show_week_numbers?(assigns))

    ~H"""
    <.dropdown
      id="mini-month-popover"
      open={@open}
      on_toggle="toggle_mini_month"
      on_close="close_mini_month"
      target={@myself}
      position={:bottom_start}
      role="dialog"
      panel_label="Pick a date"
      trigger_class="flex items-center gap-1 ml-1 md:ml-2 min-w-0 rounded px-1.5 py-1 hover:bg-tymeslot-100 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
      class="bg-white border border-tymeslot-200 rounded-xl shadow-lg p-3 w-72"
      aria-label="Pick a date"
    >
      <:trigger>
        <span
          id="calendar-period-label"
          class="text-token-sm md:text-token-base font-semibold text-tymeslot-800 truncate"
        >
          {Helpers.period_label(%{view: @view, date: @date, preferences: @preferences, user_timezone: @user_timezone})}
        </span>
        <span
          :if={@show_week_numbers and @view in [:week, :three_day, :day]}
          class="ml-1 text-token-xs font-normal text-tymeslot-400"
        >W{Helpers.week_number(@date)}</span>
        <.icon name="hero-chevron-down" class="w-3 h-3 text-tymeslot-400 shrink-0" />
      </:trigger>
      <:panel>
        <%!-- Picker-month header: prev / month-year / next --%>
        <div class="flex items-center justify-between mb-2">
          <button
            type="button"
            phx-click="mini_month_prev"
            phx-target={@myself}
            class="min-w-[32px] min-h-[32px] flex items-center justify-center rounded hover:bg-tymeslot-100 text-tymeslot-600 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            aria-label="Previous month"
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" />
          </button>
          <div class="text-token-sm font-semibold text-tymeslot-800">
            {Calendar.strftime(@cursor, "%B %Y")}
          </div>
          <button
            type="button"
            phx-click="mini_month_next"
            phx-target={@myself}
            class="min-w-[32px] min-h-[32px] flex items-center justify-center rounded hover:bg-tymeslot-100 text-tymeslot-600 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            aria-label="Next month"
          >
            <.icon name="hero-chevron-right" class="w-4 h-4" />
          </button>
        </div>

        <%!-- Weekday header row (+ optional week-number gutter) --%>
        <div
          class="grid gap-0.5 mb-1"
          style={grid_style(@show_week_numbers)}
        >
          <div :if={@show_week_numbers} class="text-center text-token-2xs font-medium text-tymeslot-400">
            Wk
          </div>
          <div
            :for={day_name <- Helpers.day_name_headers(assigns)}
            class="text-center text-token-2xs font-medium text-tymeslot-400 uppercase"
          >{String.first(day_name)}</div>
        </div>

        <%!-- 6×7 day cells --%>
        <div class="grid gap-0.5" style={grid_style(@show_week_numbers)}>
          <%= for week_days <- @weeks do %>
            <div
              :if={@show_week_numbers}
              class="flex items-center justify-center text-token-2xs text-tymeslot-400"
            >{Helpers.week_number(List.first(week_days))}</div>
            <button
              :for={day <- week_days}
              type="button"
              phx-click="navigate_to_day"
              phx-value-date={Date.to_iso8601(day)}
              phx-target={@myself}
              class={day_class(day, @cursor, @date, @today)}
              aria-label={Calendar.strftime(day, "%A, %B %-d, %Y")}
              aria-current={Date.compare(day, @date) == :eq && "date"}
            >{day.day}</button>
          <% end %>
        </div>
      </:panel>
    </.dropdown>
    """
  end

  defp grid_style(true = _show_week_numbers), do: "grid-template-columns: 1.5rem repeat(7, 1fr)"
  defp grid_style(_show_week_numbers), do: "grid-template-columns: repeat(7, 1fr)"

  defp day_class(day, cursor, selected, today) do
    base =
      "min-h-[32px] flex items-center justify-center rounded text-token-xs focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"

    cond do
      Date.compare(day, selected) == :eq ->
        "#{base} bg-turquoise-600 text-white font-semibold"

      Date.compare(day, today) == :eq ->
        "#{base} ring-1 ring-turquoise-400 text-turquoise-700 font-semibold hover:bg-turquoise-50"

      day.month != cursor.month ->
        "#{base} text-tymeslot-300 hover:bg-tymeslot-50"

      true ->
        "#{base} text-tymeslot-700 hover:bg-tymeslot-50"
    end
  end
end
