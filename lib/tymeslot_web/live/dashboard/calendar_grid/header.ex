defmodule TymeslotWeb.Dashboard.CalendarGrid.Header do
  @moduledoc "Header toolbar function component for the calendar grid."

  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Availability.Helpers, as: AvailabilityHelpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Header.SearchBox
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.MiniMonthPopover

  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :show_calendar_list, :boolean, required: true
  attr :show_view_menu, :boolean, required: true
  attr :mini_month_open, :boolean, default: false
  attr :mini_month_cursor, :any, default: nil
  attr :syncing, :boolean, required: true
  attr :timezone_display, :string, required: true
  attr :timezone_country_code, :string
  attr :preferences, :any
  attr :search_term, :string, default: ""
  attr :search_results, :list, default: []
  attr :search_open, :boolean, default: false
  attr :user_timezone, :string, default: "Etc/UTC"
  attr :myself, :any, required: true

  @spec toolbar(map()) :: Phoenix.LiveView.Rendered.t()
  def toolbar(assigns) do
    ~H"""
    <div id="calendar-grid-header" class="border-b border-tymeslot-200 bg-white sticky top-0 z-20">
      <%!--
        Two-row layout on mobile; single row on md+.
        Row 1 (always): navigation + period title.
        Row 2 (md: merged into row 1): view switcher + calendars + refresh + settings.
      --%>
      <div class="flex flex-col md:flex-row md:items-center gap-1 md:gap-2 px-3 py-2 md:px-4 md:py-3">
        <%!-- Row 1: navigation --%>
        <div class="flex items-center gap-1 md:gap-2 min-w-0">
          <button
            phx-click="prev_period"
            phx-target={@myself}
            class="min-w-[40px] min-h-[40px] flex items-center justify-center rounded hover:bg-tymeslot-100 text-tymeslot-600 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            aria-label="Previous period"
          >
            <IconComponents.icon name={:chevron_left} class="w-4 h-4" />
          </button>
          <button
            phx-click="next_period"
            phx-target={@myself}
            class="min-w-[40px] min-h-[40px] flex items-center justify-center rounded hover:bg-tymeslot-100 text-tymeslot-600 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            aria-label="Next period"
          >
            <IconComponents.icon name={:chevron_right} class="w-4 h-4" />
          </button>
          <button
            phx-click={
              JS.push("today", target: @myself)
              |> JS.dispatch("calendar:scroll-to-current", to: "#calendar-drag-zone")
            }
            class="px-2.5 py-1.5 md:px-3 text-token-sm border border-tymeslot-200 rounded hover:bg-tymeslot-50 text-tymeslot-600 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
          >Today</button>
          <MiniMonthPopover.mini_month_popover
            open={@mini_month_open}
            view={@view}
            date={@date}
            cursor={@mini_month_cursor}
            preferences={@preferences}
            user_timezone={@user_timezone}
            myself={@myself}
          />
          <div class="hidden md:block ml-1">
            <AvailabilityHelpers.timezone_display timezone_display={@timezone_display} country_code={@timezone_country_code} />
          </div>
        </div>

        <%!--
          Row 2: actions (mobile) / right-aligned row 1 (desktop).
          Use flex-wrap (not overflow-x-auto) so the toolbar reflows on narrow
          screens. overflow-x-auto forces overflow-y to compute to auto, which
          clips the dropdown panels (calendars, view switcher) that extend below
          the row via `top-full`.
        --%>
        <div class="flex flex-wrap items-center gap-1 md:gap-2 md:ml-auto">
          <div class="md:hidden">
            <AvailabilityHelpers.timezone_display timezone_display={@timezone_display} country_code={@timezone_country_code} />
          </div>
          <SearchBox.search_box
            search_term={@search_term}
            search_results={@search_results}
            search_open={@search_open}
            user_timezone={@user_timezone}
            preferences={@preferences}
            integration_colors={@integration_colors}
            myself={@myself}
          />
          <.quick_add myself={@myself} />
          <.view_switcher view={@view} show_view_menu={@show_view_menu} myself={@myself} />
          <.calendar_list_dropdown
            integrations={@integrations}
            integration_colors={@integration_colors}
            hidden_integration_ids={@hidden_integration_ids}
            show_calendar_list={@show_calendar_list}
            myself={@myself}
          />
          <.refresh_button syncing={@syncing} myself={@myself} />
          <button
            phx-click="toggle_shortcuts_help"
            phx-target={@myself}
            class="hidden md:flex min-w-[40px] min-h-[40px] items-center justify-center text-token-sm font-semibold text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            aria-label="Keyboard shortcuts"
            title="Keyboard shortcuts (?)"
          >
            ?
          </button>
          <button
            phx-click="toggle_settings"
            phx-target={@myself}
            class="min-w-[40px] min-h-[40px] flex items-center justify-center text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            aria-label="Calendar settings"
          >
            <IconComponents.icon name={:cog} class="w-4 h-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :show_calendar_list, :boolean, required: true
  attr :myself, :any, required: true

  defp calendar_list_dropdown(assigns) do
    ~H"""
    <.dropdown
      id="calendar-list-dropdown"
      open={@show_calendar_list}
      on_toggle="toggle_calendar_list"
      on_close="close_calendar_list"
      target={@myself}
      role="dialog"
      panel_label="My Calendars"
      trigger_class="min-w-[40px] min-h-[40px] px-2 md:px-3 md:py-1.5 text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 flex items-center gap-1.5 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
      class="bg-white border border-tymeslot-200 rounded-xl shadow-lg p-3 w-60"
      aria-label="Toggle calendars"
    >
      <:trigger>
        <IconComponents.icon name={:menu} class="w-4 h-4" />
        <span class="hidden md:inline">Calendars</span>
      </:trigger>
      <:panel>
        <h4 class="text-token-xs font-semibold text-tymeslot-500 uppercase tracking-wide mb-2">
          My Calendars
        </h4>
        <label
          :for={integration <- @integrations}
          class="flex items-center gap-2 py-1.5 cursor-pointer hover:bg-tymeslot-50 rounded px-1"
        >
          <input
            type="checkbox"
            checked={integration.id not in @hidden_integration_ids}
            phx-click="toggle_integration_visibility"
            phx-value-integration-id={integration.id}
            phx-target={@myself}
            class="rounded"
          />
          <div
            class={"w-3 h-3 rounded-full shrink-0 #{Helpers.color_class_for_integration(@integration_colors, integration.id)}"}
            aria-hidden="true"
          >
          </div>
          <span class="text-token-sm text-tymeslot-700 truncate">{integration.name}</span>
        </label>
        <p :if={@integrations == []} class="text-token-sm text-tymeslot-400">
          No calendars connected
        </p>
      </:panel>
    </.dropdown>
    """
  end

  attr :view, :atom, required: true
  attr :show_view_menu, :boolean, required: true
  attr :myself, :any, required: true

  defp view_switcher(assigns) do
    ~H"""
    <%!-- Dropdown on mobile --%>
    <div class="md:hidden">
      <.dropdown
        id="view-switcher-dropdown"
        open={@show_view_menu}
        on_toggle="toggle_view_menu"
        on_close="close_view_menu"
        target={@myself}
        trigger_class="min-w-[40px] min-h-[40px] px-2 text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 flex items-center gap-1 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
        class="bg-white border border-tymeslot-200 rounded-xl shadow-lg py-1 w-36"
        aria-label="Switch view"
      >
        <:trigger>
          <IconComponents.icon name={:calendar} class="w-4 h-4" />
          <span class="text-token-xs font-medium">{Helpers.view_label(@view)}</span>
          <IconComponents.icon name={:chevron_down} class="w-3 h-3" />
        </:trigger>
        <:panel>
          <button
            :for={{value, label} <- view_options()}
            phx-click="set_view"
            phx-value-view={Atom.to_string(value)}
            phx-target={@myself}
            class={"w-full text-left px-3 py-2 text-token-sm #{if @view == value, do: "bg-turquoise-50 text-turquoise-700 font-semibold", else: "text-tymeslot-600 hover:bg-tymeslot-50"}"}
          >{label}</button>
        </:panel>
      </.dropdown>
    </div>
    <%!-- Button group on desktop (pushed to the far right of the action row) --%>
    <div class="hidden md:flex md:order-last rounded-md border border-tymeslot-200 overflow-hidden text-token-sm">
      <button
        :for={{{value, label}, idx} <- view_options() |> Enum.with_index()}
        phx-click="set_view"
        phx-value-view={Atom.to_string(value)}
        phx-target={@myself}
        class={"px-3 py-1.5 focus:outline-hidden focus:z-10 focus:ring-2 focus:ring-turquoise-400 #{if idx > 0, do: "border-l border-tymeslot-200"} #{if @view == value, do: "bg-turquoise-600 text-white", else: "bg-white text-tymeslot-600 hover:bg-tymeslot-50"}"}
      >{label}</button>
    </div>
    """
  end

  defp view_options do
    [
      {:day, "Day"},
      {:three_day, "3 Days"},
      {:week, "Week"},
      {:month, "Month"},
      {:agenda, "Agenda"}
    ]
  end

  attr :myself, :any, required: true

  defp quick_add(assigns) do
    ~H"""
    <%!--
      Single-line natural-language quick-add. Submitting parses the text
      server-side and opens the create modal pre-filled (e.g. "Lunch 1pm for 90m").
      The input is cleared after submit; if nothing time-like parses, the modal
      still opens with the typed text as the title.
    --%>
    <form
      phx-submit="quick_add"
      phx-target={@myself}
      class="hidden sm:flex items-center"
    >
      <div class="relative">
        <span class="pointer-events-none absolute inset-y-0 left-2 flex items-center text-tymeslot-400">
          <.icon name="hero-plus-circle-mini" class="w-4 h-4" />
        </span>
        <input
          id="calendar-quick-add-input"
          type="text"
          name="text"
          value=""
          autocomplete="off"
          placeholder="Quick add — e.g. Lunch 1pm"
          aria-label="Quick add event"
          class="w-44 lg:w-56 pl-8 pr-2 py-1.5 text-token-sm text-tymeslot-700 placeholder:text-tymeslot-400 border border-tymeslot-200 rounded-md focus:outline-hidden focus:ring-2 focus:ring-turquoise-400 focus:border-turquoise-400"
        />
      </div>
    </form>
    """
  end

  attr :syncing, :boolean, required: true
  attr :myself, :any, required: true

  defp refresh_button(assigns) do
    ~H"""
    <button
      phx-click={
        JS.push("refresh", target: @myself)
        |> JS.dispatch("calendar:scroll-to-current", to: "#calendar-drag-zone")
      }
      disabled={@syncing}
      class="min-w-[40px] min-h-[40px] px-2 md:px-3 md:py-1.5 flex items-center justify-center gap-1.5 text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 disabled:opacity-60 disabled:cursor-not-allowed focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
      aria-label="Refresh"
    >
      <IconComponents.icon name={:refresh} class={if @syncing, do: "w-4 h-4 animate-spin", else: "w-4 h-4"} />
      <span class="hidden md:inline">Refresh</span>
    </button>
    """
  end
end
