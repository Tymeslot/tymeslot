defmodule TymeslotWeb.Dashboard.Calendar.Toolbar do
  @moduledoc """
  The calendar surface's single toolbar row: Create, Today, previous and
  next, the period title (which opens a date picker), search (which opens
  the command bar), the view switch and display options. Rare actions
  (import, refresh, settings) stay out of it, as the spec asks.

  Navigation controls use `Navigation.js/3`, so the grid redraws in the
  browser in the same click that patches the URL.

  Below 40rem it is hidden and `PhoneHeader` and `PhoneTabs` take its place.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.DisplayOptions
  alias TymeslotWeb.Dashboard.Calendar.FilterChip
  alias TymeslotWeb.Dashboard.Calendar.MiniMonth
  alias TymeslotWeb.Dashboard.Calendar.Navigation
  alias TymeslotWeb.Dashboard.Calendar.PeriodLabels

  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :today, :any, required: true
  attr :days, :list, required: true
  attr :locale, :string, required: true
  attr :open_menu, :atom, default: nil
  attr :mini_cursor, :any, required: true
  attr :week_start, :atom, required: true
  attr :preferences, :map, required: true, doc: "the organiser's `CalendarPreferencesSchema`"
  attr :rail_open, :boolean, required: true
  attr :calendar_focus, :boolean, default: false
  attr :hidden_count, :integer, required: true
  attr :set_name, :string, default: nil
  attr :time_format, :string, required: true, doc: ~s("24h" or "12h")
  attr :target, :any, required: true
  attr :week_numbers, :boolean, default: false

  @spec toolbar(map()) :: Phoenix.LiveView.Rendered.t()
  def toolbar(assigns) do
    ~H"""
    <%!-- Five views and the display options need about 920px: narrower, the
         views wrap to a second row rather than running off the edge. --%>
    <div
      id="calendar-toolbar"
      class="flex min-h-11 shrink-0 flex-wrap items-center gap-x-2 gap-y-1 border-b border-tymeslot-200 bg-white px-3 py-1 max-sm:hidden"
    >
      <.icon_button
        id="calendar-rail-toggle"
        icon="hero-bars-3"
        size={:sm}
        label={dgettext("dashboard_calendar", "Show or hide the calendar list")}
        aria-controls={@rail_open && "calendar-rail"}
        aria-expanded={to_string(@rail_open)}
        phx-click="calendar:toggle_rail"
        phx-target={@target}
        class="hidden md:inline-flex"
      />
      <%!-- Between 640 and 767px the rail is hidden and the phone header is not shown. --%>
      <.icon_button
        id="calendar-calendars-button"
        icon="hero-rectangle-stack"
        size={:sm}
        label={dgettext("dashboard_calendar", "Calendars")}
        aria-haspopup="dialog"
        aria-expanded={to_string(@open_menu == :calendars)}
        phx-click="calendar:toggle_menu"
        phx-value-menu="calendars"
        phx-target={@target}
        class="hidden sm:inline-flex md:hidden"
      />
      <.action_button
        id="calendar-create"
        variant={:primary}
        size={:sm}
        icon="hero-plus"
        aria-keyshortcuts="c"
        phx-click={JS.dispatch("calendar:quick-create", to: "#calendar-canvas")}
      >
        {dgettext("dashboard_calendar", "Create")}
      </.action_button>
      <.action_button
        id="calendar-today"
        variant={:secondary}
        size={:sm}
        phx-click={Navigation.js(@view, @today, from: {@view, @date})}
      >
        {dgettext("dashboard_calendar", "Today")}
      </.action_button>
      <div class="flex items-center">
        <.icon_button
          id="calendar-prev"
          icon="hero-chevron-left"
          size={:sm}
          label={PeriodLabels.step_label(@view, :previous)}
          phx-click={Navigation.js(@view, Period.shift(@view, @date, -1), step: -1)}
        />
        <.icon_button
          id="calendar-next"
          icon="hero-chevron-right"
          size={:sm}
          label={PeriodLabels.step_label(@view, :next)}
          phx-click={Navigation.js(@view, Period.shift(@view, @date, 1), step: 1)}
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
        aria-label={
          dgettext("dashboard_calendar", "Choose a date, %{period}",
            period: PeriodLabels.title(@view, @date, @days, @locale)
          )
        }
        trigger_class="flex items-center gap-1 rounded-token-md px-2 py-1 hover:bg-tymeslot-50 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
        class="mt-1 w-72 rounded-token-xl bg-white p-3 shadow-lg ring-1 ring-tymeslot-200"
      >
        <:trigger>
          <span
            id="calendar-period-title"
            class="whitespace-nowrap text-token-lg font-semibold text-tymeslot-900"
          >
            {PeriodLabels.title(@view, @date, @days, @locale)}
          </span>
          <.icon name="hero-chevron-down-mini" class="h-4 w-4 text-tymeslot-500" />
        </:trigger>
        <:panel>
          <MiniMonth.mini_month
            id="calendar-picker-month"
            cursor={@mini_cursor}
            view={@view}
            date={@date}
            days={@days}
            today={@today}
            week_start={@week_start}
            locale={@locale}
            target={@target}
            week_numbers={@week_numbers}
          />
        </:panel>
      </.dropdown>
      <div class="flex-1"></div>
      <.icon_button
        id="calendar-search"
        icon="hero-magnifying-glass"
        size={:sm}
        label={dgettext("dashboard_calendar_power", "Search and commands")}
        aria-keyshortcuts="Control+K Meta+K"
        aria-haspopup="dialog"
        phx-click={JS.dispatch("calendar:command-open", to: "#calendar-canvas")}
      />
      <FilterChip.filter_chip
        hidden_count={@hidden_count}
        set_name={@set_name}
        rail_open={@rail_open}
        target={@target}
      />
      <div
        role="group"
        aria-label={dgettext("dashboard_calendar", "View")}
        class="ml-auto inline-flex gap-0.5 rounded-token-lg border border-tymeslot-200 bg-white p-0.5"
      >
        <button
          :for={view <- Period.views()}
          type="button"
          id={"calendar-view-#{view}"}
          aria-pressed={to_string(view == @view)}
          phx-click={Navigation.js(view, @date, from: {@view, @date})}
          class={[
            "inline-flex items-center whitespace-nowrap rounded-token-md px-3 py-1 text-token-sm font-semibold transition-colors",
            "focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-turquoise-400",
            if(view == @view,
              do: "bg-turquoise-700 text-white shadow-sm",
              else: "text-tymeslot-600 hover:bg-tymeslot-50 hover:text-tymeslot-900"
            )
          ]}
        >
          {PeriodLabels.view_label(view)}
        </button>
      </div>
      <%!-- Focus mode changes nothing below 1024px, where the menu is a
           drawer. No phx-target: DashboardLive owns the layout. --%>
      <.icon_button
        id="calendar-focus-toggle"
        icon={if @calendar_focus, do: "hero-arrows-pointing-in", else: "hero-arrows-pointing-out"}
        size={:sm}
        label={
          if @calendar_focus,
            do: dgettext("dashboard_calendar_power", "Leave focus mode"),
            else: dgettext("dashboard_calendar_power", "Focus mode")
        }
        aria-pressed={to_string(@calendar_focus)}
        aria-keyshortcuts="f"
        phx-click="calendar:toggle_focus"
        class="hidden lg:inline-flex"
      />
      <.dropdown
        id="calendar-display-options"
        open={@open_menu == :display}
        on_toggle="calendar:toggle_menu"
        on_close="calendar:close_menu"
        target={@target}
        trigger_attrs={[{"phx-value-menu", "display"}, {"id", "calendar-display-toggle"}]}
        role="dialog"
        panel_label={dgettext("dashboard_calendar", "Display options")}
        aria-label={dgettext("dashboard_calendar", "Display options")}
        trigger_class="icon-button icon-button--neutral icon-button--sm"
        class="mt-1 max-h-[min(36rem,80dvh)] w-80 overflow-y-auto rounded-token-xl bg-white p-4 shadow-lg ring-1 ring-tymeslot-200"
      >
        <:trigger>
          <.icon name="hero-adjustments-horizontal" class="h-4 w-4" />
        </:trigger>
        <:panel>
          <DisplayOptions.display_options
            id_prefix="calendar"
            preferences={@preferences}
            time_format={@time_format}
            calendar_focus={@calendar_focus}
            target={@target}
          />
        </:panel>
      </.dropdown>
    </div>
    """
  end
end
