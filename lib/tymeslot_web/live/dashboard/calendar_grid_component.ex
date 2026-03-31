defmodule TymeslotWeb.Dashboard.CalendarGridComponent do
  @moduledoc """
  LiveComponent rendering a week/day/month calendar grid backed by cached calendar events.

  State assigns:
  - `:view`               — `:week` | `:day` | `:month` (default `:week`)
  - `:date`               — `Date.t()` anchor date (default `Date.utc_today()`)
  - `:events`             — list of cached events (default `[]`)
  - `:integrations`       — list of active integrations (default `[]`)
  - `:integration_colors` — map `%{id => color_class}` (default `%{}`)
  - `:loading`            — boolean (default `false`)
  - `:selected_event`     — selected event or `nil`
  - `:current_time`       — `DateTime.t()` for the current-time indicator
  - `:hidden_integration_ids` — list of integration IDs to hide (default `[]`)
  - `:preferences`        — `CalendarPreferencesSchema.t()` or `nil`
  """
  use TymeslotWeb, :live_component

  alias Tymeslot.CalendarGrid
  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.Availability.Helpers, as: AvailabilityHelpers
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Modals

  @impl Phoenix.LiveComponent
  def mount(socket) do
    socket =
      socket
      |> assign(:view, :week)
      |> assign(:date, Date.utc_today())
      |> assign(:events, [])
      |> assign(:integrations, [])
      |> assign(:integration_colors, %{})
      |> assign(:loading, false)
      |> assign(:selected_event, nil)
      |> assign(:current_time, DateTime.utc_now())
      |> assign(:hidden_integration_ids, [])
      |> assign(:preferences, nil)
      |> assign(:show_calendar_list, false)
      |> assign(:show_view_menu, false)
      |> assign(:show_settings, false)
      |> assign(:creating_event, nil)
      |> assign(:recurrence_prompt, nil)
      |> assign(:confirm_delete_event, nil)
      |> assign(:saving_event, false)
      |> assign(:deleting_event, false)
      |> assign(:owned_integration_ids, MapSet.new())
      |> assign(:visible_events, [])
      |> assign(:visible_days, [])
      |> assign(:user_timezone, "UTC")
      |> assign(:timezone_display, "UTC")
      |> assign(:timezone_country_code, nil)
      |> assign(:syncing, false)
      |> assign(:sync_total, 0)
      |> assign(:sync_completed, 0)
      |> assign(:stale_integrations, [])
      |> assign(:oldest_sync_at, nil)

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def update(%{action: :revert_event, original_event: original} = assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:action, :original_event]))

    reverted_events =
      Enum.map(socket.assigns.events, fn e ->
        if e.id == original.id, do: original, else: e
      end)

    selected = socket.assigns.selected_event

    socket =
      socket
      |> assign(:events, reverted_events)
      |> then(fn s ->
        if selected && selected.id == original.id,
          do: assign(s, :selected_event, original),
          else: s
      end)
      |> Helpers.precompute_derived()

    {:ok, socket}
  end

  def update(%{action: :refresh_events} = assigns, socket) do
    was_syncing = socket.assigns.syncing

    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:syncing, false)
      |> assign(:sync_total, 0)
      |> assign(:sync_completed, 0)
      |> Helpers.load_integrations()
      |> Helpers.load_events()

    if was_syncing, do: send(self(), :calendar_sync_flash)

    {:ok, socket}
  end

  def update(%{action: :reload_events} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> Helpers.load_events()

    {:ok, socket}
  end

  def update(%{action: :event_created} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:creating_event, nil)
      |> assign(:saving_event, false)
      |> Helpers.load_events()

    {:ok, socket}
  end

  def update(%{action: :event_create_failed} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:saving_event, false)

    {:ok, socket}
  end

  def update(%{action: :event_moved} = assigns, socket) do
    new_uid = assigns[:new_event_uid]
    new_integration_id = assigns[:new_event_integration_id]

    socket =
      socket
      |> assign(Map.drop(assigns, [:action, :new_event_uid, :new_event_integration_id]))
      |> Helpers.load_events()

    new_event =
      Enum.find(socket.assigns.events, fn e ->
        e.uid == new_uid and e.calendar_integration_id == new_integration_id
      end)

    {:ok, assign(socket, :selected_event, new_event)}
  end

  def update(%{action: :event_deleted} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:confirm_delete_event, nil)
      |> assign(:deleting_event, false)
      |> assign(:selected_event, nil)
      |> Helpers.load_events()

    {:ok, socket}
  end

  def update(%{action: :event_delete_failed} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:confirm_delete_event, nil)
      |> assign(:deleting_event, false)

    {:ok, socket}
  end

  def update(%{action: :events_updated} = assigns, socket) do
    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> Helpers.load_events()

    {:ok, socket}
  end

  def update(%{action: :integration_synced} = assigns, socket) do
    completed = socket.assigns.sync_completed + 1
    total = socket.assigns.sync_total

    socket =
      socket
      |> assign(Map.drop(assigns, [:action]))
      |> assign(:sync_completed, completed)

    socket =
      if completed >= total do
        send(self(), :calendar_sync_flash)

        socket
        |> assign(:syncing, false)
        |> assign(:sync_total, 0)
        |> assign(:sync_completed, 0)
        |> Helpers.load_integrations()
        |> Helpers.load_events()
      else
        socket
      end

    {:ok, socket}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    socket =
      if Map.get(socket.assigns, :_initialized) do
        socket
      else
        Process.send_after(self(), :tick, 60_000)

        socket
        |> assign(:_initialized, true)
        |> Helpers.load_integrations()
        |> Helpers.load_events()
        |> maybe_auto_refresh()
      end

    {:ok, socket}
  end

  @impl Phoenix.LiveComponent
  def handle_event("show_event", params, socket),
    do: EventHandlers.handle_show_event(params, socket)

  def handle_event("close_event_detail", params, socket),
    do: EventHandlers.handle_close_event_detail(params, socket)

  def handle_event("update_event_title", params, socket),
    do: EventHandlers.handle_update_event_title(params, socket)

  def handle_event("update_event_location", params, socket),
    do: EventHandlers.handle_update_event_location(params, socket)

  def handle_event("update_event_description", params, socket),
    do: EventHandlers.handle_update_event_description(params, socket)

  def handle_event("update_event_calendar", params, socket),
    do: EventHandlers.handle_update_event_calendar(params, socket)

  def handle_event("update_event_time", params, socket),
    do: EventHandlers.handle_update_event_time(params, socket)

  def handle_event("prev_period", params, socket),
    do: EventHandlers.handle_prev_period(params, socket)

  def handle_event("next_period", params, socket),
    do: EventHandlers.handle_next_period(params, socket)

  def handle_event("today", params, socket),
    do: EventHandlers.handle_today(params, socket)

  def handle_event("set_view", params, socket),
    do: EventHandlers.handle_set_view(params, socket)

  def handle_event("navigate_to_day", params, socket),
    do: EventHandlers.handle_navigate_to_day(params, socket)

  def handle_event("toggle_calendar_list", params, socket),
    do: EventHandlers.handle_toggle_calendar_list(params, socket)

  def handle_event("toggle_view_menu", params, socket),
    do: EventHandlers.handle_toggle_view_menu(params, socket)

  def handle_event("toggle_integration_visibility", params, socket),
    do: EventHandlers.handle_toggle_integration_visibility(params, socket)

  def handle_event("refresh", params, socket),
    do: EventHandlers.handle_refresh(params, socket)

  def handle_event("event_dropped", params, socket),
    do: EventHandlers.handle_event_dropped(params, socket)

  def handle_event("event_resized", params, socket),
    do: EventHandlers.handle_event_resized(params, socket)

  def handle_event("show_create_form", params, socket),
    do: EventHandlers.handle_show_create_form(params, socket)

  def handle_event("close_create_form", params, socket),
    do: EventHandlers.handle_close_create_form(params, socket)

  def handle_event("update_create_title", params, socket),
    do: EventHandlers.handle_update_create_title(params, socket)

  def handle_event("update_create_time", params, socket),
    do: EventHandlers.handle_update_create_time(params, socket)

  def handle_event("update_create_integration", params, socket),
    do: EventHandlers.handle_update_create_integration(params, socket)

  def handle_event("save_event", params, socket),
    do: EventHandlers.handle_save_event(params, socket)

  def handle_event("request_delete_event", params, socket),
    do: EventHandlers.handle_request_delete_event(params, socket)

  def handle_event("confirm_delete_event", params, socket),
    do: EventHandlers.handle_confirm_delete_event(params, socket)

  def handle_event("cancel_delete_event", params, socket),
    do: EventHandlers.handle_cancel_delete_event(params, socket)

  def handle_event("confirm_recurrence_scope", params, socket),
    do: EventHandlers.handle_confirm_recurrence_scope(params, socket)

  def handle_event("cancel_recurrence_prompt", params, socket),
    do: EventHandlers.handle_cancel_recurrence_prompt(params, socket)

  def handle_event("toggle_settings", params, socket),
    do: EventHandlers.handle_toggle_settings(params, socket)

  def handle_event("close_settings", params, socket),
    do: EventHandlers.handle_close_settings(params, socket)

  def handle_event("update_week_start", params, socket),
    do: EventHandlers.handle_update_preference(params, socket, :week_start_day)

  def handle_event("update_time_format", params, socket),
    do: EventHandlers.handle_update_preference(params, socket, :time_format)

  def handle_event("update_default_view", params, socket),
    do: EventHandlers.handle_update_default_view(params, socket)

  def handle_event("toggle_week_numbers", params, socket),
    do: EventHandlers.handle_toggle_preference(params, socket, :show_week_numbers)

  def handle_event("toggle_weekends", params, socket),
    do: EventHandlers.handle_toggle_preference(params, socket, :show_weekends)

  def handle_event("set_mobile_view", params, socket),
    do: EventHandlers.handle_set_mobile_view(params, socket)

  def handle_event("navigate_swipe", params, socket),
    do: EventHandlers.handle_navigate_swipe(params, socket)

  defp maybe_auto_refresh(socket) do
    if socket.assigns.stale_integrations != [] do
      user_id = socket.assigns.current_user.id
      {:ok, result} = CalendarGrid.refresh_events(user_id)
      Process.send_after(self(), :reset_calendar_sync, 30_000)

      socket
      |> assign(:syncing, true)
      |> assign(:sync_total, result.enqueued + result.skipped)
      |> assign(:sync_completed, result.skipped)
    else
      socket
    end
  end

  defp format_sync_age(nil), do: "never synced"

  defp format_sync_age(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86_400)}d ago"
    end
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div id="calendar-grid" class="flex flex-col h-full relative" phx-hook="CalendarMobile" phx-target={@myself}>
      <%!-- Header --%>
      <div id="calendar-grid-header" class="flex flex-wrap items-center gap-2 px-3 py-2 md:px-4 md:py-3 border-b border-tymeslot-200 bg-white sticky top-0 z-20">
        <%!-- Left: navigation controls --%>
        <div class="flex items-center gap-1 md:gap-2">
          <button
            phx-click="prev_period"
            phx-target={@myself}
            class="p-1.5 rounded hover:bg-tymeslot-100 text-tymeslot-600"
            aria-label="Previous period"
          >
            <IconComponents.icon name={:chevron_left} class="w-4 h-4" />
          </button>
          <button
            phx-click="next_period"
            phx-target={@myself}
            class="p-1.5 rounded hover:bg-tymeslot-100 text-tymeslot-600"
            aria-label="Next period"
          >
            <IconComponents.icon name={:chevron_right} class="w-4 h-4" />
          </button>
          <button
            phx-click="today"
            phx-target={@myself}
            class="px-2 py-1 md:px-3 text-sm border border-tymeslot-200 rounded hover:bg-tymeslot-50 text-tymeslot-600"
          >Today</button>
          <h2 class="text-sm font-semibold text-tymeslot-800 ml-1 md:ml-2 truncate">
            <%= Helpers.period_label(assigns) %>
            <%= if Helpers.show_week_numbers?(assigns) and @view in [:week, :day] do %>
              <span class="ml-1 text-xs font-normal text-tymeslot-400">W<%= Helpers.week_number(@date) %></span>
            <% end %>
          </h2>
          <AvailabilityHelpers.timezone_display timezone_display={@timezone_display} country_code={@timezone_country_code} />
        </div>
        <%!-- Right: actions --%>
        <div class="flex items-center gap-1 md:gap-2 ml-auto">
          <%!-- Calendars toggle --%>
          <div class="relative">
            <button
              phx-click="toggle_calendar_list"
              phx-target={@myself}
              class="p-1.5 md:px-3 md:py-1.5 text-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 flex items-center gap-1.5"
              aria-label="Toggle calendars"
            >
              <IconComponents.icon name={:menu} class="w-4 h-4" />
              <span class="hidden md:inline">Calendars</span>
            </button>
            <%= if @show_calendar_list do %>
              <div
                id="calendar-list-panel"
                class="absolute right-0 top-full mt-1 z-30 bg-white border border-tymeslot-200 rounded-xl shadow-lg p-3 w-60"
              >
                <h4 class="text-xs font-semibold text-tymeslot-500 uppercase tracking-wide mb-2">My Calendars</h4>
                <%= for integration <- @integrations do %>
                  <label class="flex items-center gap-2 py-1.5 cursor-pointer hover:bg-tymeslot-50 rounded px-1">
                    <input
                      type="checkbox"
                      checked={integration.id not in @hidden_integration_ids}
                      phx-click="toggle_integration_visibility"
                      phx-value-integration-id={integration.id}
                      phx-target={@myself}
                      class="rounded"
                    />
                    <div class={"w-3 h-3 rounded-full flex-shrink-0 #{Helpers.color_dot(assigns, integration)}"}></div>
                    <span class="text-sm text-tymeslot-700 truncate"><%= integration.name %></span>
                  </label>
                <% end %>
                <%= if @integrations == [] do %>
                  <p class="text-sm text-tymeslot-400">No calendars connected</p>
                <% end %>
              </div>
            <% end %>
          </div>
          <%!-- View switcher: dropdown on mobile, button group on desktop --%>
          <div class="relative md:hidden">
            <button
              phx-click="toggle_view_menu"
              phx-target={@myself}
              class="p-1.5 text-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 flex items-center gap-1"
              aria-label="Switch view"
            >
              <IconComponents.icon name={:calendar} class="w-4 h-4" />
              <span class="text-xs font-medium"><%= Helpers.view_label(@view) %></span>
              <IconComponents.icon name={:chevron_down} class="w-3 h-3" />
            </button>
            <%= if @show_view_menu do %>
              <div class="absolute right-0 top-full mt-1 z-30 bg-white border border-tymeslot-200 rounded-xl shadow-lg py-1 w-32">
                <%= for {value, label} <- [{"day", "Day"}, {"week", "Week"}, {"month", "Month"}] do %>
                  <button
                    phx-click="set_view"
                    phx-value-view={value}
                    phx-target={@myself}
                    class={"w-full text-left px-3 py-2 text-sm #{if @view == String.to_existing_atom(value), do: "bg-turquoise-50 text-turquoise-700 font-semibold", else: "text-tymeslot-600 hover:bg-tymeslot-50"}"}
                  ><%= label %></button>
                <% end %>
              </div>
            <% end %>
          </div>
          <div class="hidden md:flex rounded-md border border-tymeslot-200 overflow-hidden text-sm">
            <%= for {value, label} <- [{"day", "Day"}, {"week", "Week"}, {"month", "Month"}] do %>
              <button
                phx-click="set_view"
                phx-value-view={value}
                phx-target={@myself}
                class={"px-3 py-1.5 #{if value != "day", do: "border-l border-tymeslot-200"} #{if @view == String.to_existing_atom(value), do: "bg-turquoise-600 text-white", else: "bg-white text-tymeslot-600 hover:bg-tymeslot-50"}"}
              ><%= label %></button>
            <% end %>
          </div>
          <%!-- Refresh button --%>
          <button
            phx-click="refresh"
            phx-target={@myself}
            disabled={@syncing}
            class="p-1.5 md:px-3 md:py-1.5 flex items-center gap-1.5 text-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50 disabled:opacity-60 disabled:cursor-not-allowed"
            aria-label="Refresh"
          >
            <IconComponents.icon name={:refresh} class={if @syncing, do: "w-4 h-4 animate-spin", else: "w-4 h-4"} />
            <span class="hidden md:inline">Refresh</span>
          </button>
          <%!-- Settings button --%>
          <button
            phx-click="toggle_settings"
            phx-target={@myself}
            class="p-1.5 text-sm text-tymeslot-600 border border-tymeslot-200 rounded-md hover:bg-tymeslot-50"
            aria-label="Calendar settings"
          >
            <IconComponents.icon name={:cog} class="w-4 h-4" />
          </button>
        </div>
      </div>

      <%= if @stale_integrations != [] and not @syncing do %>
        <div class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-amber-50 border-b border-amber-200 text-sm text-amber-700">
          <svg class="w-4 h-4 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z" />
          </svg>
          <span>
            <%= if @oldest_sync_at, do: "Calendar data may be outdated (last synced #{format_sync_age(@oldest_sync_at)}).", else: "Some calendars have never been synced." %>
          </span>
          <button
            phx-click="refresh"
            phx-target={@myself}
            class="underline hover:text-amber-900 font-medium"
          >Refresh now</button>
        </div>
      <% end %>
      <%= if @syncing do %>
        <div class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-turquoise-50 border-b border-turquoise-200 text-sm text-turquoise-700">
          <IconComponents.icon name={:refresh} class="w-4 h-4 animate-spin flex-shrink-0" />
          <span>Syncing calendars<%= if @sync_total > 1, do: " (#{@sync_completed}/#{@sync_total})", else: "" %>...</span>
        </div>
      <% end %>

      <div class={if @view == :month, do: "hidden", else: "contents"}>
        <%!-- All-day banner row (T-44 will flesh this out) --%>
        <div
          id="calendar-allday-row"
          class="grid border-b border-tymeslot-200 bg-white"
          style={"grid-template-columns: var(--time-axis) repeat(#{Helpers.col_count(assigns)}, 1fr)"}
        >
          <div class="text-xs text-tymeslot-400 flex items-end justify-end pr-2 pb-1">all-day</div>
          <%= for day <- @visible_days do %>
            <div class="border-l border-tymeslot-100 p-0.5 min-h-[1.5rem] flex flex-col gap-0.5">
              <%= for event <- Helpers.all_day_events_for_day(assigns, day) do %>
                <div
                  class={"rounded px-1 text-xs font-medium text-white truncate cursor-pointer #{Helpers.color_for_event(assigns, event)}"}
                  phx-click="show_event"
                  phx-value-event-id={event.id}
                  phx-target={@myself}
                >
                  <%= event.title || "(No title)" %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- Main scrollable area --%>
        <div id="calendar-drag-zone" phx-hook="CalendarDrag" phx-target={@myself} class="flex-1 overflow-y-auto overflow-x-auto relative" data-current-top-rem={Helpers.top_rem(@current_time, @user_timezone)}>
          <%!-- Day column headers (sticky) --%>
          <div
            class="grid border-b border-tymeslot-200 sticky top-0 bg-white z-10"
            style={"grid-template-columns: var(--time-axis) repeat(#{Helpers.col_count(assigns)}, 1fr)"}
          >
            <div class="flex items-center justify-end pr-2">
              <%!-- Timezone label (T-49) --%>
              <span class="text-xs text-tymeslot-400"><%= Helpers.user_tz_abbr(assigns) %></span>
            </div>
            <%= for day <- @visible_days do %>
              <div class={"text-center py-2 border-l border-tymeslot-100 #{Helpers.day_header_class(day)}"}>
                <%= if @view == :day do %>
                  <span class="text-sm font-medium hidden sm:inline"><%= Calendar.strftime(day, "%A, %B %-d, %Y") %></span>
                  <span class="text-sm font-medium sm:hidden"><%= Calendar.strftime(day, "%a %-d") %></span>
                <% else %>
                  <span class="text-sm"><%= Calendar.strftime(day, "%a %-d") %></span>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Time grid --%>
          <div id="calendar-create-zone" phx-hook="CalendarCreate" phx-target={@myself}>
          <div id="calendar-resize-zone" phx-hook="CalendarResize" phx-target={@myself}>
          <div
            id="calendar-time-grid"
            class="grid relative"
            style={"grid-template-columns: var(--time-axis) repeat(#{Helpers.col_count(assigns)}, 1fr)"}
          >
            <%!-- Time axis --%>
            <div class="relative">
              <%= for hour <- 0..23 do %>
                <div class="h-16 border-b border-tymeslot-100 flex items-start justify-end pr-2 pt-0.5">
                  <span class="text-xs text-tymeslot-400">
                    <%= Helpers.format_hour(hour, assigns) %>
                  </span>
                </div>
              <% end %>
            </div>

            <%!-- Day columns --%>
            <%= for day <- @visible_days do %>
              <div class="relative border-l border-tymeslot-100" data-day-col={Date.to_iso8601(day)} style="min-height: 96rem;">
                <%!-- Hour grid lines --%>
                <%= for _hour <- 0..23 do %>
                  <div class="h-16 border-b border-tymeslot-100"></div>
                <% end %>
                <%!-- Events --%>
                <%= for {event, col_idx, total_cols} <- Helpers.positioned_events_for_day(assigns, day) do %>
                  <div
                    id={"event-#{event.id}"}
                    class={"absolute rounded px-1 py-0.5 #{if @view == :day, do: "text-sm", else: "text-xs"} font-medium text-white overflow-hidden cursor-pointer hover:brightness-90 group #{Helpers.color_for_event(assigns, event)}"}
                    style={"top: #{Helpers.top_rem(event.start_at, @user_timezone)}rem; height: #{Helpers.height_rem(event.start_at, event.end_at)}rem; left: #{Helpers.left_pct(col_idx, total_cols)}%; width: calc(#{Helpers.width_pct(total_cols)}% - 2px);"}
                    phx-click="show_event"
                    phx-value-event-id={event.id}
                    phx-target={@myself}
                    data-draggable="true"
                    data-event-id={event.id}
                    data-event-date={Date.to_iso8601(DateTime.to_date(event.start_at))}
                    data-start-minutes={DateTime.shift_zone!(event.start_at, @user_timezone) |> then(&(&1.hour * 60 + &1.minute))}
                    data-duration-minutes={max(15, round(DateTime.diff(event.end_at, event.start_at, :second) / 60))}
                  >
                    <div class="truncate font-semibold"><%= event.title || "(No title)" %></div>
                    <div class="opacity-80"><%= Helpers.format_time_range(event, Helpers.time_format(assigns)) %></div>
                    <div data-resize-handle class="absolute bottom-0 left-0 right-0 h-2 cursor-s-resize opacity-0 group-hover:opacity-100 bg-black/10 rounded-b"></div>
                  </div>
                <% end %>
                <%!-- Current time indicator --%>
                <%= if Date.compare(day, DateTime.to_date(@current_time)) == :eq do %>
                  <div class="absolute left-0 right-0 z-20 pointer-events-none"
                       style={"top: #{Helpers.top_rem(@current_time, @user_timezone)}rem"}>
                    <div class="h-0.5 bg-red-500 relative">
                      <div class="w-2.5 h-2.5 rounded-full bg-red-500 absolute -left-1.5 -top-[0.1875rem]"></div>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
          </div>
          </div>
        </div>
      </div>

      <div id="calendar-month-grid" class={if @view == :month, do: "flex-1 overflow-auto", else: "hidden"}>
          <%!-- Day-of-week headers --%>
          <div class="grid border-b border-tymeslot-200 bg-white sticky top-0"
            style={if Helpers.show_week_numbers?(assigns), do: "grid-template-columns: 2rem repeat(7, 1fr)", else: "grid-template-columns: repeat(7, 1fr)"}>
            <%= if Helpers.show_week_numbers?(assigns) do %>
              <div class="text-center text-xs font-medium text-tymeslot-400 py-1 sm:py-2">Wk</div>
            <% end %>
            <%= for day_name <- Helpers.day_name_headers(assigns) do %>
              <div class="text-center text-xs font-medium text-tymeslot-500 py-1 sm:py-2 uppercase tracking-wide">
                <span class="hidden sm:inline"><%= day_name %></span>
                <span class="sm:hidden"><%= String.first(day_name) %></span>
              </div>
            <% end %>
          </div>

          <%!-- 6x7 day cells --%>
          <div class="grid"
            style={if Helpers.show_week_numbers?(assigns), do: "grid-template-columns: 2rem repeat(7, 1fr)", else: "grid-template-columns: repeat(7, 1fr)"}>
            <%= for {week_days, week_idx} <- @visible_days |> Enum.chunk_every(7) |> Enum.with_index() do %>
              <%= if Helpers.show_week_numbers?(assigns) do %>
                <div class={"text-xs text-tymeslot-400 flex items-start justify-center pt-1 border-b border-r border-tymeslot-100 #{if week_idx > 0, do: "", else: ""}"}>
                  <%= Helpers.week_number(List.first(week_days)) %>
                </div>
              <% end %>
              <%= for day <- week_days do %>
              <div
                class={"min-h-14 sm:min-h-24 border-b border-r border-tymeslot-100 p-0.5 sm:p-1 cursor-pointer hover:bg-tymeslot-50 #{Helpers.month_cell_class(day, assigns)}"}
                phx-click="navigate_to_day"
                phx-value-date={Date.to_iso8601(day)}
                phx-target={@myself}
              >
                <div class={"text-xs font-medium mb-0.5 #{if Date.compare(day, Date.utc_today()) == :eq, do: "w-5 h-5 rounded-full bg-turquoise-600 text-white flex items-center justify-center text-center", else: (if day.month != assigns.date.month, do: "text-tymeslot-300", else: "text-tymeslot-600")}"}>
                  <%= day.day %>
                </div>

                <% day_evts = Helpers.day_events(assigns, day) %>
                <%!-- Mobile: colored dots; Desktop: event titles --%>
                <div class="hidden sm:block">
                  <%= for event <- Enum.take(day_evts, 3) do %>
                    <div
                      class={"rounded px-1 text-xs text-white truncate mb-0.5 cursor-pointer #{Helpers.color_for_event(assigns, event)}"}
                      phx-click="show_event"
                      phx-value-event-id={event.id}
                      phx-target={@myself}
                    >
                      <%= event.title || "(No title)" %>
                    </div>
                  <% end %>
                  <%= if length(day_evts) > 3 do %>
                    <div class="text-xs text-tymeslot-400 mt-0.5">
                      +<%= length(day_evts) - 3 %> more
                    </div>
                  <% end %>
                </div>
                <div class="sm:hidden flex flex-wrap gap-0.5 mt-0.5">
                  <%= for event <- Enum.take(day_evts, 4) do %>
                    <div
                      class={"w-1.5 h-1.5 rounded-full #{Helpers.color_for_event(assigns, event)}"}
                      phx-click="show_event"
                      phx-value-event-id={event.id}
                      phx-target={@myself}
                    ></div>
                  <% end %>
                  <%= if length(day_evts) > 4 do %>
                    <span class="text-[10px] text-tymeslot-400 leading-none">+<%= length(day_evts) - 4 %></span>
                  <% end %>
                </div>
              </div>
            <% end %>
            <% end %>
          </div>
      </div>

      <%= if @creating_event do %>
        <Modals.create_event_modal
          creating_event={@creating_event}
          integrations={@integrations}
          integration_colors={@integration_colors}
          saving={@saving_event}
          user_timezone={@user_timezone}
          myself={@myself}
        />
      <% end %>
      <%= if @recurrence_prompt do %>
        <Modals.recurrence_prompt_modal
          recurrence_prompt={@recurrence_prompt}
          myself={@myself}
        />
      <% end %>
      <%= if @show_settings do %>
        <Modals.settings_modal
          preferences={@preferences}
          myself={@myself}
        />
      <% end %>
      <%= if @selected_event do %>
        <Modals.event_detail_modal
          selected_event={@selected_event}
          integrations={@integrations}
          integration_colors={@integration_colors}
          user_timezone={@user_timezone}
          time_format={Helpers.time_format(assigns)}
          myself={@myself}
          editable={MapSet.member?(@owned_integration_ids, @selected_event.calendar_integration_id)}
        />
      <% end %>
      <%= if @confirm_delete_event do %>
        <Modals.confirm_delete_modal
          event={@confirm_delete_event}
          deleting={@deleting_event}
          myself={@myself}
        />
      <% end %>
    </div>
    """
  end
end
