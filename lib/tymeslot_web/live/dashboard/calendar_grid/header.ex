defmodule TymeslotWeb.Dashboard.CalendarGrid.Header do
  @moduledoc "Header toolbar function component for the calendar grid."

  use TymeslotWeb, :html

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
        Two-row layout at every size. The full toolbar never fits on a single
        row at common laptop widths, so rather than collapse to one row on md+
        (which forced the view switcher to wrap onto its own detached line and
        looked scrambled), we keep two stable rows:
          Row 1: navigation + period title, with the view switcher pinned right.
          Row 2: search, quick-add, calendars, refresh and settings.
        flex-wrap on each row lets it reflow gracefully when space is tight.
      --%>
      <div class="flex flex-col gap-1 md:gap-2 px-3 py-2 md:px-4 md:py-3">
        <%!-- Row 1: navigation (left) + view switcher (right) --%>
        <div class="flex items-center gap-1 md:gap-2 min-w-0">
          <button
            phx-click="prev_period"
            phx-target={@myself}
            class="min-w-[40px] min-h-[40px] flex items-center justify-center rounded hover:bg-tymeslot-100 text-tymeslot-600 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            aria-label="Previous period"
          >
            <.icon name="hero-chevron-left" class="w-4 h-4" />
          </button>
          <button
            phx-click="next_period"
            phx-target={@myself}
            class="min-w-[40px] min-h-[40px] flex items-center justify-center rounded hover:bg-tymeslot-100 text-tymeslot-600 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
            aria-label="Next period"
          >
            <.icon name="hero-chevron-right" class="w-4 h-4" />
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
          <div class="hidden md:block ml-1 min-w-0">
            <AvailabilityHelpers.timezone_display timezone_display={@timezone_display} country_code={@timezone_country_code} />
          </div>

          <%!--
            Segmented view switcher pinned to the right of the navigation row on
            md+. On mobile the compact `view_menu` lives in the tools row below,
            so this slot collapses (no `ml-auto` element) and the navigation
            keeps its natural left-aligned width.
          --%>
          <div class="hidden md:block ml-auto pl-1 shrink-0">
            <.view_tabs view={@view} myself={@myself} />
          </div>
        </div>

        <%!--
          Row 2: tools. Use flex-wrap (not overflow-x-auto) so the toolbar
          reflows on narrow screens. overflow-x-auto forces overflow-y to compute
          to auto, which clips the dropdown panels (calendars, search) that
          extend below the row via `top-full`.
        --%>
        <div class="flex flex-wrap items-center gap-1 md:gap-2">
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
          <.view_menu view={@view} show_view_menu={@show_view_menu} myself={@myself} />
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
            <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
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
        <.icon name="hero-bars-3" class="w-4 h-4" />
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

  # Compact dropdown for the tools row on mobile (hidden on md+, where the
  # segmented `view_tabs` takes over on the navigation row).
  defp view_menu(assigns) do
    ~H"""
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
          <.icon name="hero-calendar-days" class="w-4 h-4" />
          <span class="text-token-xs font-medium">{Helpers.view_label(@view)}</span>
          <.icon name="hero-chevron-down" class="w-3 h-3" />
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
    """
  end

  attr :view, :atom, required: true
  attr :myself, :any, required: true

  # Segmented button group pinned to the right of the navigation row on md+
  # (hidden on mobile, where the compact `view_menu` takes over).
  defp view_tabs(assigns) do
    ~H"""
    <div class="hidden md:flex rounded-md border border-tymeslot-200 overflow-hidden text-token-sm">
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

  # Opens the create-event modal directly. The full draft is built and edited in
  # the modal itself, so there is no inline text entry to parse here.
  defp quick_add(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="show_create_form"
      phx-target={@myself}
      class="hidden sm:flex min-w-[40px] min-h-[40px] px-2 md:px-3 md:py-1.5 items-center gap-1.5 text-token-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
      aria-label="Add event"
    >
      <.icon name="hero-plus-circle-mini" class="w-4 h-4" />
      <span>Quick add</span>
    </button>
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
      <.icon name="hero-arrow-path" class={if @syncing, do: "w-4 h-4 animate-spin", else: "w-4 h-4"} />
      <span class="hidden md:inline">Refresh</span>
    </button>
    """
  end
end
