defmodule TymeslotWeb.Dashboard.CalendarGrid.GridViews do
  @moduledoc "Grid view function components for the calendar grid (week/day and month)."

  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  attr :view, :atom, required: true
  attr :visible_days, :list, required: true
  attr :visible_events, :list, required: true
  attr :events, :list, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :current_time, :any, required: true
  attr :user_timezone, :string, required: true
  attr :preferences, :any
  attr :stale_integrations, :list, required: true
  attr :oldest_sync_at, :any
  attr :syncing, :boolean, required: true
  attr :sync_total, :integer, required: true
  attr :sync_completed, :integer, required: true
  attr :date, :any, required: true
  attr :myself, :any, required: true

  @spec week_day_view(map()) :: Phoenix.LiveView.Rendered.t()
  def week_day_view(assigns) do
    ~H"""
    <.status_banners
      stale_integrations={@stale_integrations}
      syncing={@syncing}
      sync_total={@sync_total}
      sync_completed={@sync_completed}
      oldest_sync_at={@oldest_sync_at}
      myself={@myself}
    />

    <div class={if @view == :month, do: "hidden", else: "contents"}>
      <%!-- All-day banner row --%>
      <div
        id="calendar-allday-row"
        class="grid border-b border-tymeslot-200 bg-white"
        style={"grid-template-columns: var(--time-axis) repeat(#{Helpers.col_count(assigns)}, 1fr)"}
      >
        <div class="text-token-xs text-tymeslot-400 flex items-end justify-end pr-2 pb-1">all-day</div>
        <div :for={day <- @visible_days} class="border-l border-tymeslot-100 p-0.5 min-h-[1.5rem] flex flex-col gap-0.5">
          <div
            :for={event <- Helpers.all_day_events_for_day(assigns, day)}
            class={"rounded px-1 text-token-xs font-medium text-white truncate cursor-pointer #{Helpers.color_for_event(assigns, event)}"}
            phx-click="show_event"
            phx-value-event-id={event.id}
            phx-target={@myself}
          >
            <img
              :if={Map.get(event, :created_by_tymeslot)}
              src="/images/brand/logo.svg"
              alt="Tymeslot"
              class="inline-block w-3 h-3 opacity-60 mr-0.5 align-text-bottom"
            /><%= event.summary || "(No title)" %>
          </div>
        </div>
      </div>

      <%!-- Main scrollable area --%>
      <div id="calendar-drag-zone" phx-hook="CalendarDrag" phx-target={@myself} class="flex-1 overflow-y-auto overflow-x-auto relative" data-current-top-rem={Helpers.top_rem(@current_time, @user_timezone)}>
        <%!-- Day column headers (sticky) --%>
        <div
          class="grid border-b border-tymeslot-200 sticky top-0 bg-white z-10"
          style={"grid-template-columns: var(--time-axis) repeat(#{Helpers.col_count(assigns)}, 1fr)"}
        >
          <div class="flex items-center justify-end pr-2">
            <span class="text-token-xs text-tymeslot-400"><%= Helpers.user_tz_abbr(assigns) %></span>
          </div>
          <div :for={day <- @visible_days} class={"text-center py-2 border-l border-tymeslot-100 #{Helpers.day_header_class(day)}"}>
            <span :if={@view == :day} class="text-token-sm font-medium hidden sm:inline"><%= Calendar.strftime(day, "%A, %B %-d, %Y") %></span>
            <span :if={@view == :day} class="text-token-sm font-medium sm:hidden"><%= Calendar.strftime(day, "%a %-d") %></span>
            <span :if={@view != :day} class="text-token-sm"><%= Calendar.strftime(day, "%a %-d") %></span>
          </div>
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
            <div :for={hour <- 0..23} class="h-16 border-b border-tymeslot-100 flex items-start justify-end pr-2 pt-0.5">
              <span class="text-token-xs text-tymeslot-400">
                <%= Helpers.format_hour(hour, assigns) %>
              </span>
            </div>
          </div>

          <%!-- Day columns --%>
          <div :for={day <- @visible_days} class="relative border-l border-tymeslot-100" data-day-col={Date.to_iso8601(day)} style="min-height: 96rem;">
            <%!-- Hour grid lines --%>
            <div :for={_hour <- 0..23} class="h-16 border-b border-tymeslot-100"></div>
            <%!-- Events --%>
            <div
              :for={{event, col_idx, total_cols} <- Helpers.positioned_events_for_day(assigns, day)}
              id={"event-#{event.id}-#{day}"}
              class={"absolute rounded px-1 py-0.5 #{if @view == :day, do: "text-token-sm", else: "text-token-xs"} font-medium text-white overflow-hidden cursor-pointer hover:brightness-90 group #{Helpers.color_for_event(assigns, event)}"}
              style={"top: #{Helpers.top_rem(event.start_at, @user_timezone)}rem; height: #{Helpers.height_rem(event.start_at, event.end_at)}rem; left: #{Helpers.left_pct(col_idx, total_cols)}%; width: calc(#{Helpers.width_pct(total_cols)}% - 2px);"}
              phx-click="show_event"
              phx-value-event-id={event.id}
              phx-target={@myself}
              data-draggable="true"
              data-event-id={event.id}
              data-event-date={Date.to_iso8601(day)}
              data-start-minutes={DateTime.shift_zone!(event.start_at, @user_timezone) |> then(&(&1.hour * 60 + &1.minute))}
              data-duration-minutes={max(15, round(DateTime.diff(Map.get(event, :display_end_at, event.end_at), Map.get(event, :display_start_at, event.start_at), :second) / 60))}
            >
              <div class="truncate font-semibold"><%= event.summary || "(No title)" %></div>
              <div class="opacity-80"><%= Helpers.format_display_time_range(event, Helpers.time_format(assigns), @user_timezone) %></div>
              <img
                :if={Map.get(event, :created_by_tymeslot)}
                src="/images/brand/logo.svg"
                alt="Tymeslot event"
                class="absolute top-0.5 right-0.5 w-3 h-3 opacity-60"
              />
              <div data-resize-handle class="absolute bottom-0 left-0 right-0 h-2 cursor-s-resize opacity-0 group-hover:opacity-100 bg-black/10 rounded-b"></div>
            </div>
            <%!-- Current time indicator --%>
            <div
              :if={Date.compare(day, DateTime.to_date(@current_time)) == :eq}
              class="absolute left-0 right-0 z-20 pointer-events-none"
              style={"top: #{Helpers.top_rem(@current_time, @user_timezone)}rem"}
            >
              <div class="h-0.5 bg-red-500 relative">
                <div class="w-2.5 h-2.5 rounded-full bg-red-500 absolute -left-1.5 -top-[0.1875rem]"></div>
              </div>
            </div>
          </div>
        </div>
        </div>
        </div>
      </div>
    </div>
    """
  end

  attr :view, :atom, required: true
  attr :visible_days, :list, required: true
  attr :visible_events, :list, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :date, :any, required: true
  attr :user_timezone, :string, required: true
  attr :preferences, :any
  attr :myself, :any, required: true

  @spec month_view(map()) :: Phoenix.LiveView.Rendered.t()
  def month_view(assigns) do
    ~H"""
    <div id="calendar-month-grid" class={if @view == :month, do: "flex-1 overflow-auto", else: "hidden"}>
      <%!-- Day-of-week headers --%>
      <div class="grid border-b border-tymeslot-200 bg-white sticky top-0"
        style={if Helpers.show_week_numbers?(assigns), do: "grid-template-columns: 2rem repeat(7, 1fr)", else: "grid-template-columns: repeat(7, 1fr)"}>
        <div :if={Helpers.show_week_numbers?(assigns)} class="text-center text-token-xs font-medium text-tymeslot-400 py-1 sm:py-2">Wk</div>
        <div :for={day_name <- Helpers.day_name_headers(assigns)} class="text-center text-token-xs font-medium text-tymeslot-500 py-1 sm:py-2 uppercase tracking-wide">
          <span class="hidden sm:inline"><%= day_name %></span>
          <span class="sm:hidden"><%= String.first(day_name) %></span>
        </div>
      </div>

      <%!-- 6x7 day cells --%>
      <div class="grid"
        style={if Helpers.show_week_numbers?(assigns), do: "grid-template-columns: 2rem repeat(7, 1fr)", else: "grid-template-columns: repeat(7, 1fr)"}>
        <%= for {week_days, week_idx} <- @visible_days |> Enum.chunk_every(7) |> Enum.with_index() do %>
          <div
            :if={Helpers.show_week_numbers?(assigns)}
            class={"text-token-xs text-tymeslot-400 flex items-start justify-center pt-1 border-b border-r border-tymeslot-100 #{if week_idx > 0, do: "", else: ""}"}
          >
            <%= Helpers.week_number(List.first(week_days)) %>
          </div>
          <div
            :for={day <- week_days}
            class={"min-h-14 sm:min-h-24 border-b border-r border-tymeslot-100 p-0.5 sm:p-1 cursor-pointer hover:bg-tymeslot-50 #{Helpers.month_cell_class(day, assigns)}"}
            phx-click="navigate_to_day"
            phx-value-date={Date.to_iso8601(day)}
            phx-target={@myself}
          >
            <div class={"text-token-xs font-medium mb-0.5 #{if Date.compare(day, Date.utc_today()) == :eq, do: "w-5 h-5 rounded-full bg-turquoise-600 text-white flex items-center justify-center text-center", else: (if day.month != assigns.date.month, do: "text-tymeslot-300", else: "text-tymeslot-600")}"}>
              <%= day.day %>
            </div>

            <% day_evts = Helpers.day_events(assigns, day) %>
            <%!-- Mobile: colored dots; Desktop: event titles --%>
            <div class="hidden sm:block">
              <div
                :for={event <- Enum.take(day_evts, 3)}
                class={"rounded px-1 text-token-xs text-white truncate mb-0.5 cursor-pointer #{Helpers.color_for_event(assigns, event)}"}
                phx-click="show_event"
                phx-value-event-id={event.id}
                phx-target={@myself}
              >
                <img
                  :if={Map.get(event, :created_by_tymeslot)}
                  src="/images/brand/logo.svg"
                  alt="Tymeslot"
                  class="inline-block w-3 h-3 opacity-60 mr-0.5 align-text-bottom"
                /><%= event.summary || "(No title)" %>
              </div>
              <div :if={length(day_evts) > 3} class="text-token-xs text-tymeslot-400 mt-0.5">
                +<%= length(day_evts) - 3 %> more
              </div>
            </div>
            <div class="sm:hidden flex flex-wrap gap-0.5 mt-0.5">
              <div
                :for={event <- Enum.take(day_evts, 4)}
                class={"w-1.5 h-1.5 rounded-full #{Helpers.color_for_event(assigns, event)}"}
                phx-click="show_event"
                phx-value-event-id={event.id}
                phx-target={@myself}
              ></div>
              <span :if={length(day_evts) > 4} class="text-token-xs text-tymeslot-400 leading-none">+<%= length(day_evts) - 4 %></span>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :stale_integrations, :list, required: true
  attr :syncing, :boolean, required: true
  attr :sync_total, :integer, required: true
  attr :sync_completed, :integer, required: true
  attr :oldest_sync_at, :any
  attr :myself, :any, required: true

  defp status_banners(assigns) do
    ~H"""
    <div :if={@stale_integrations != [] and not @syncing} class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-amber-50 border-b border-amber-200 text-token-sm text-amber-700">
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
    <div :if={@syncing} class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-turquoise-50 border-b border-turquoise-200 text-token-sm text-turquoise-700">
      <IconComponents.icon name={:refresh} class="w-4 h-4 animate-spin flex-shrink-0" />
      <span>Syncing calendars<%= if @sync_total > 1, do: " (#{@sync_completed}/#{@sync_total})", else: "" %>...</span>
    </div>
    """
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
end
