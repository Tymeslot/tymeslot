defmodule TymeslotWeb.Dashboard.Calendar.Toolbar do
  @moduledoc """
  The calendar surface's single toolbar row: Today, previous and next, the
  period title (which opens a date picker), the view switch and display
  options. Rare actions (import, refresh, settings) stay out of it, as the
  spec asks.

  Navigation controls use `Navigation.js/2`, so the grid redraws in the
  browser in the same click that patches the URL.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.MiniMonth
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Helpers.LocaleFormat

  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :today, :any, required: true
  attr :days, :list, required: true
  attr :locale, :string, required: true
  attr :open_menu, :atom, default: nil
  attr :mini_cursor, :any, required: true
  attr :week_start, :atom, required: true
  attr :density, :string, required: true
  attr :fold_night, :boolean, required: true
  attr :target, :any, required: true

  @spec toolbar(map()) :: Phoenix.LiveView.Rendered.t()
  def toolbar(assigns) do
    ~H"""
    <div
      id="calendar-toolbar"
      role="toolbar"
      aria-label={dgettext("dashboard_calendar", "Calendar controls")}
      class="flex h-11 shrink-0 items-center gap-2 border-b border-tymeslot-200 bg-white px-3"
    >
      <%!-- Rail toggle --%>
      <.action_button
        id="calendar-today"
        variant={:secondary}
        size={:sm}
        phx-click={Navigation.js(@view, @today)}
      >
        {dgettext("dashboard_calendar", "Today")}
      </.action_button>
      <div class="flex items-center">
        <.icon_button
          id="calendar-prev"
          icon="hero-chevron-left"
          size={:sm}
          label={step_label(@view, :previous)}
          phx-click={Navigation.js(@view, Period.shift(@view, @date, -1))}
        />
        <.icon_button
          id="calendar-next"
          icon="hero-chevron-right"
          size={:sm}
          label={step_label(@view, :next)}
          phx-click={Navigation.js(@view, Period.shift(@view, @date, 1))}
        />
      </div>
      <.dropdown
        id="calendar-date-picker"
        open={@open_menu == :date}
        on_toggle="calendar:toggle_menu"
        on_close="calendar:close_menu"
        target={@target}
        trigger_attrs={[{"phx-value-menu", "date"}]}
        position={:bottom_start}
        role="dialog"
        panel_label={dgettext("dashboard_calendar", "Choose a date")}
        trigger_class="flex items-center gap-1 rounded-token-md px-2 py-1 hover:bg-tymeslot-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
        class="mt-1 w-72 rounded-token-xl bg-white p-3 shadow-lg ring-1 ring-tymeslot-200"
      >
        <:trigger>
          <span
            id="calendar-period-title"
            class="whitespace-nowrap text-token-lg font-semibold text-tymeslot-900"
          >
            {period_title(@view, @date, @days, @locale)}
          </span>
          <.icon name="hero-chevron-down-mini" class="h-4 w-4 text-tymeslot-500" />
        </:trigger>
        <:panel>
          <MiniMonth.mini_month
            id="calendar-picker-month"
            cursor={@mini_cursor}
            view={@view}
            days={@days}
            today={@today}
            week_start={@week_start}
            locale={@locale}
            target={@target}
          />
        </:panel>
      </.dropdown>
      <div class="flex-1"></div>
      <%!-- Hidden calendars chip --%>
      <div
        role="group"
        aria-label={dgettext("dashboard_calendar", "View")}
        class="inline-flex gap-0.5 rounded-token-lg border border-tymeslot-200 bg-white p-0.5"
      >
        <button
          :for={{view, label} <- view_options()}
          type="button"
          id={"calendar-view-#{view}"}
          aria-pressed={to_string(view == @view)}
          phx-click={Navigation.js(view, @date)}
          class={[
            "inline-flex items-center whitespace-nowrap rounded-token-md px-3 py-1 text-token-sm font-semibold transition-colors",
            "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-turquoise-400",
            if(view == @view,
              do: "bg-turquoise-700 text-white shadow-sm",
              else: "text-tymeslot-600 hover:bg-tymeslot-50 hover:text-tymeslot-900"
            )
          ]}
        >
          {label}
        </button>
      </div>
      <.dropdown
        id="calendar-display-options"
        open={@open_menu == :display}
        on_toggle="calendar:toggle_menu"
        on_close="calendar:close_menu"
        target={@target}
        trigger_attrs={[{"phx-value-menu", "display"}]}
        role="dialog"
        panel_label={dgettext("dashboard_calendar", "Display options")}
        aria-label={dgettext("dashboard_calendar", "Display options")}
        trigger_class="icon-button icon-button--neutral icon-button--sm"
        class="mt-1 w-72 space-y-4 rounded-token-xl bg-white p-4 shadow-lg ring-1 ring-tymeslot-200"
      >
        <:trigger>
          <.icon name="hero-adjustments-horizontal" class="h-4 w-4" />
        </:trigger>
        <:panel>
          <div class="flex items-center justify-between gap-3">
            <span class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar", "Density")}
            </span>
            <.segmented_control
              id="calendar-density"
              size={:sm}
              value={@density}
              on_change="calendar:set_density"
              param="option"
              target={@target}
              aria_label={dgettext("dashboard_calendar", "Density")}
            >
              <:option value="comfortable" label={dgettext("dashboard_calendar", "Comfortable")} />
              <:option value="compact" label={dgettext("dashboard_calendar", "Compact")} />
            </.segmented_control>
          </div>
          <div class="flex items-center justify-between gap-3">
            <span class="text-token-sm font-medium text-tymeslot-700">
              {dgettext("dashboard_calendar", "Fold early hours")}
            </span>
            <StatusSwitch.status_switch
              id="calendar-fold-night"
              checked={@fold_night}
              on_change="calendar:toggle_fold_night"
              target={@target}
              size={:small}
              aria_label={dgettext("dashboard_calendar", "Fold early hours")}
            />
          </div>
          <div class="border-t border-tymeslot-100 pt-3">
            <%!-- No phx-target: DashboardLive swaps the component. --%>
            <.action_button
              id="calendar-back-to-old"
              variant={:ghost}
              size={:sm}
              phx-click={JS.push("calendar:switch_surface", value: %{enabled: false})}
            >
              {dgettext("dashboard_calendar", "Back to the old calendar")}
            </.action_button>
          </div>
        </:panel>
      </.dropdown>
    </div>
    """
  end

  defp view_options do
    [
      day: dgettext("dashboard_calendar", "Day"),
      three_day: dgettext("dashboard_calendar", "3 days"),
      week: dgettext("dashboard_calendar", "Week")
    ]
  end

  defp step_label(:day, :previous), do: dgettext("dashboard_calendar", "Previous day")
  defp step_label(:day, :next), do: dgettext("dashboard_calendar", "Next day")

  defp step_label(:three_day, :previous),
    do: dgettext("dashboard_calendar", "Previous three days")

  defp step_label(:three_day, :next), do: dgettext("dashboard_calendar", "Next three days")
  defp step_label(:week, :previous), do: dgettext("dashboard_calendar", "Previous week")
  defp step_label(:week, :next), do: dgettext("dashboard_calendar", "Next week")

  defp period_title(:day, date, _days, locale), do: LocaleFormat.format_weekday_date(date, locale)

  defp period_title(_view, _date, days, locale) do
    first = List.first(days)
    last = List.last(days)

    cond do
      {first.year, first.month} == {last.year, last.month} ->
        LocaleFormat.format_month_year(first.month, first.year, locale)

      first.year == last.year ->
        "#{LocaleFormat.format_month_name(first.month, locale, :short)} – " <>
          LocaleFormat.format_month_year(last.month, last.year, locale)

      true ->
        "#{LocaleFormat.format_month_year(first.month, first.year, locale)} – " <>
          LocaleFormat.format_month_year(last.month, last.year, locale)
    end
  end
end
