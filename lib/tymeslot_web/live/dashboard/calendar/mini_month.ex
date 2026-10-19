defmodule TymeslotWeb.Dashboard.Calendar.MiniMonth do
  @moduledoc """
  A month of day buttons with the visible range marked, used in the rail, in
  the period title's date picker and in the phone's date sheet
  (`size={:touch}`), with an optional column of ISO week numbers. A day click
  navigates like every other control (`Navigation.js/3`), keeping the current
  view.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Helpers.LocaleFormat

  @day_sizes %{compact: "h-7 text-token-xs", touch: "h-11 text-token-sm"}
  @arrow_sizes %{compact: nil, touch: "h-11 w-11"}
  @columns %{
    true => "grid grid-cols-[1.5rem_repeat(7,minmax(0,1fr))] gap-0",
    false => "grid grid-cols-7 gap-0"
  }

  attr :id, :string, required: true
  attr :cursor, :any, required: true, doc: "the first of the month shown"
  attr :view, :atom, required: true
  attr :date, :any, required: true, doc: "the date the grid is shown around"
  attr :days, :list, required: true, doc: "the days the grid shows, marked"
  attr :today, :any, required: true
  attr :week_start, :atom, required: true
  attr :locale, :string, required: true
  attr :target, :any, required: true

  attr :week_numbers, :boolean,
    default: false,
    doc: "a leading column with each row's ISO week (`Period.week_number/1`)"

  attr :size, :atom,
    default: :compact,
    values: [:compact, :touch],
    doc: ":touch makes each day a 44px target, for the date sheet on a phone"

  @spec mini_month(map()) :: Phoenix.LiveView.Rendered.t()
  def mini_month(assigns) do
    assigns =
      assign(assigns,
        arrow: Map.fetch!(@arrow_sizes, assigns.size),
        columns: Map.fetch!(@columns, assigns.week_numbers),
        weeks: Period.month_matrix(assigns.cursor, assigns.week_start),
        initials: initials(assigns.locale, assigns.week_start)
      )

    ~H"""
    <div id={@id} class="select-none">
      <div class="mb-1 flex items-center justify-between">
        <span
          id={"#{@id}-label"}
          aria-live="polite"
          class="text-token-sm font-semibold text-tymeslot-800"
        >
          {LocaleFormat.format_month_year(@cursor.month, @cursor.year, @locale)}
        </span>
        <div class="flex items-center">
          <.icon_button
            icon="hero-chevron-left-mini"
            size={:sm}
            class={@arrow}
            label={dgettext("dashboard_calendar", "Previous month")}
            phx-click={JS.push("calendar:mini_shift", value: %{dir: -1}, target: @target)}
          />
          <.icon_button
            icon="hero-chevron-right-mini"
            size={:sm}
            class={@arrow}
            label={dgettext("dashboard_calendar", "Next month")}
            phx-click={JS.push("calendar:mini_shift", value: %{dir: 1}, target: @target)}
          />
        </div>
      </div>
      <div
        class={[@columns, "text-center text-token-2xs font-semibold text-tymeslot-500"]}
        aria-hidden="true"
      >
        <span :if={@week_numbers}></span>
        <span :for={initial <- @initials}>{initial}</span>
      </div>
      <div role="group" aria-labelledby={"#{@id}-label"}>
        <div :for={week <- @weeks} class={@columns}>
          <span :if={@week_numbers} class="cal-weeknum" role="img" aria-label={week_label(week)}>
            {Period.week_number(week)}
          </span>
          <button
            :for={day <- week}
            type="button"
            phx-click={
              Navigation.js(@view, day,
                from: {@view, @date},
                unchanged: JS.push("calendar:close_menu", target: @target)
              )
            }
            aria-label={LocaleFormat.format_weekday_date(day, @locale)}
            aria-current={if(day == @today, do: "date")}
            aria-pressed={to_string(day in @days)}
            class={day_class(day, @cursor, @days, @today, @size)}
          >
            {day.day}
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp week_label(week),
    do: dgettext("dashboard_calendar_power", "Week %{number}", number: Period.week_number(week))

  defp day_class(day, cursor, days, today, size) do
    [
      Map.fetch!(@day_sizes, size),
      "rounded-token-md tabular-nums focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400",
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
