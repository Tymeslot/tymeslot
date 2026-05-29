defmodule TymeslotWeb.Dashboard.CalendarGrid.Header do
  @moduledoc "Header toolbar function component for the calendar grid."

  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Availability.Helpers, as: AvailabilityHelpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  attr :view, :atom, required: true
  attr :date, :any, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :show_calendar_list, :boolean, required: true
  attr :show_view_menu, :boolean, required: true
  attr :syncing, :boolean, required: true
  attr :timezone_display, :string, required: true
  attr :timezone_country_code, :string
  attr :preferences, :any
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
            class="min-w-[40px] min-h-[40px] flex items-center justify-center rounded hover:bg-tymeslot-100 text-tymeslot-600 focus:outline-none focus:ring-2 focus:ring-turquoise-400"
            aria-label="Previous period"
          >
            <IconComponents.icon name={:chevron_left} class="w-4 h-4" />
          </button>
          <button
            phx-click="next_period"
            phx-target={@myself}
            class="min-w-[40px] min-h-[40px] flex items-center justify-center rounded hover:bg-tymeslot-100 text-tymeslot-600 focus:outline-none focus:ring-2 focus:ring-turquoise-400"
            aria-label="Next period"
          >
            <IconComponents.icon name={:chevron_right} class="w-4 h-4" />
          </button>
          <button
            phx-click="today"
            phx-target={@myself}
            class="px-2.5 py-1.5 md:px-3 text-token-sm border border-tymeslot-200 rounded hover:bg-tymeslot-50 text-tymeslot-600 focus:outline-none focus:ring-2 focus:ring-turquoise-400"
          >Today</button>
          <h2 class="text-token-sm md:text-token-base font-semibold text-tymeslot-800 ml-1 md:ml-2 min-w-0 truncate">
            <%= Helpers.period_label(assigns) %>
            <span :if={Helpers.show_week_numbers?(assigns) and @view in [:week, :three_day, :day]} class="ml-1 text-token-xs font-normal text-tymeslot-400">W<%= Helpers.week_number(@date) %></span>
          </h2>
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
            phx-click="toggle_settings"
            phx-target={@myself}
            class="min-w-[40px] min-h-[40px] flex items-center justify-center text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 focus:outline-none focus:ring-2 focus:ring-turquoise-400"
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
    <div class="relative">
      <button
        phx-click="toggle_calendar_list"
        phx-target={@myself}
        class="min-w-[40px] min-h-[40px] px-2 md:px-3 md:py-1.5 text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 flex items-center gap-1.5 focus:outline-none focus:ring-2 focus:ring-turquoise-400"
        aria-label="Toggle calendars"
        aria-expanded={to_string(@show_calendar_list)}
      >
        <IconComponents.icon name={:menu} class="w-4 h-4" />
        <span class="hidden md:inline">Calendars</span>
      </button>
      <div
        :if={@show_calendar_list}
        id="calendar-list-panel"
        class="absolute right-0 top-full mt-1 z-30 bg-white border border-tymeslot-200 rounded-xl shadow-lg p-3 w-60"
        aria-labelledby="calendar-list-panel-heading"
      >
        <h4 id="calendar-list-panel-heading" class="text-token-xs font-semibold text-tymeslot-500 uppercase tracking-wide mb-2">My Calendars</h4>
        <label :for={integration <- @integrations} class="flex items-center gap-2 py-1.5 cursor-pointer hover:bg-tymeslot-50 rounded px-1">
          <input
            type="checkbox"
            checked={integration.id not in @hidden_integration_ids}
            phx-click="toggle_integration_visibility"
            phx-value-integration-id={integration.id}
            phx-target={@myself}
            class="rounded"
          />
          <div class={"w-3 h-3 rounded-full flex-shrink-0 #{Helpers.color_class_for_integration(@integration_colors, integration.id)}"} aria-hidden="true"></div>
          <span class="text-token-sm text-tymeslot-700 truncate"><%= integration.name %></span>
        </label>
        <p :if={@integrations == []} class="text-token-sm text-tymeslot-400">No calendars connected</p>
      </div>
    </div>
    """
  end

  attr :view, :atom, required: true
  attr :show_view_menu, :boolean, required: true
  attr :myself, :any, required: true

  defp view_switcher(assigns) do
    ~H"""
    <%!-- Dropdown on mobile --%>
    <div class="relative md:hidden">
      <button
        phx-click="toggle_view_menu"
        phx-target={@myself}
        class="min-w-[40px] min-h-[40px] px-2 text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 flex items-center gap-1 focus:outline-none focus:ring-2 focus:ring-turquoise-400"
        aria-label="Switch view"
        aria-expanded={to_string(@show_view_menu)}
      >
        <IconComponents.icon name={:calendar} class="w-4 h-4" />
        <span class="text-token-xs font-medium"><%= Helpers.view_label(@view) %></span>
        <IconComponents.icon name={:chevron_down} class="w-3 h-3" />
      </button>
      <div :if={@show_view_menu} class="absolute right-0 top-full mt-1 z-30 bg-white border border-tymeslot-200 rounded-xl shadow-lg py-1 w-36">
        <button
          :for={{value, label} <- view_options()}
          phx-click="set_view"
          phx-value-view={Atom.to_string(value)}
          phx-target={@myself}
          class={"w-full text-left px-3 py-2 text-token-sm #{if @view == value, do: "bg-turquoise-50 text-turquoise-700 font-semibold", else: "text-tymeslot-600 hover:bg-tymeslot-50"}"}
        ><%= label %></button>
      </div>
    </div>
    <%!-- Button group on desktop (pushed to the far right of the action row) --%>
    <div class="hidden md:flex md:order-last rounded-md border border-tymeslot-200 overflow-hidden text-token-sm">
      <button
        :for={{{value, label}, idx} <- view_options() |> Enum.with_index()}
        phx-click="set_view"
        phx-value-view={Atom.to_string(value)}
        phx-target={@myself}
        class={"px-3 py-1.5 focus:outline-none focus:z-10 focus:ring-2 focus:ring-turquoise-400 #{if idx > 0, do: "border-l border-tymeslot-200"} #{if @view == value, do: "bg-turquoise-600 text-white", else: "bg-white text-tymeslot-600 hover:bg-tymeslot-50"}"}
      ><%= label %></button>
    </div>
    """
  end

  defp view_options do
    [{:day, "Day"}, {:three_day, "3 Days"}, {:week, "Week"}, {:month, "Month"}]
  end

  attr :syncing, :boolean, required: true
  attr :myself, :any, required: true

  defp refresh_button(assigns) do
    ~H"""
    <button
      phx-click="refresh"
      phx-target={@myself}
      disabled={@syncing}
      class="min-w-[40px] min-h-[40px] px-2 md:px-3 md:py-1.5 flex items-center justify-center gap-1.5 text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 disabled:opacity-60 disabled:cursor-not-allowed focus:outline-none focus:ring-2 focus:ring-turquoise-400"
      aria-label="Refresh"
    >
      <IconComponents.icon name={:refresh} class={if @syncing, do: "w-4 h-4 animate-spin", else: "w-4 h-4"} />
      <span class="hidden md:inline">Refresh</span>
    </button>
    """
  end
end
