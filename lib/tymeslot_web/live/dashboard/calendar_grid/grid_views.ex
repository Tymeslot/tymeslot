defmodule TymeslotWeb.Dashboard.CalendarGrid.GridViews do
  @moduledoc "Grid view function components for the calendar grid (week/day and month)."

  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @timed_views [:week, :three_day, :day]
  @allday_visible_limit 2

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
    day_layouts =
      Map.new(assigns.visible_days, fn day -> {day, Helpers.layout_for_day(assigns, day)} end)

    assigns =
      assigns
      |> assign(:col_count, Helpers.col_count(assigns))
      |> assign(:is_timed, assigns.view in @timed_views)
      |> assign(
        :today_visible?,
        today_in_visible?(assigns.visible_days, assigns.current_time, assigns.user_timezone)
      )
      |> assign(:current_top_rem, Helpers.top_rem(assigns.current_time, assigns.user_timezone))
      |> assign(:day_layouts, day_layouts)

    ~H"""
    <.status_banners
      stale_integrations={@stale_integrations}
      syncing={@syncing}
      sync_total={@sync_total}
      sync_completed={@sync_completed}
      oldest_sync_at={@oldest_sync_at}
      myself={@myself}
    />

    <div class={if @is_timed, do: "contents", else: "hidden"}>
      <%!-- All-day banner row --%>
      <div
        id="calendar-allday-row"
        class="grid border-b border-tymeslot-200 bg-white"
        style={"grid-template-columns: var(--time-axis) repeat(#{@col_count}, 1fr)"}
      >
        <div class="text-token-xs text-tymeslot-400 flex items-end justify-end pr-2 pb-1">all-day</div>
        <.allday_cell
          :for={day <- @visible_days}
          assigns_ref={assigns}
          day={day}
          myself={@myself}
        />
      </div>

      <%!-- Main scrollable area --%>
      <div
        id="calendar-drag-zone"
        phx-hook="CalendarDrag"
        phx-target={@myself}
        class="flex-1 overflow-y-auto overflow-x-auto relative"
        data-current-top-rem={@current_top_rem}
        data-show-now={to_string(@today_visible?)}
      >
        <%!-- Day column headers (sticky) --%>
        <div
          class="grid border-b border-tymeslot-200 sticky top-0 bg-white z-10 shadow-[0_1px_0_rgba(0,0,0,0.02)]"
          style={"grid-template-columns: var(--time-axis) repeat(#{@col_count}, 1fr)"}
        >
          <div class="flex items-center justify-end pr-2 sticky left-0 bg-white z-10">
            <span class="text-token-xs text-tymeslot-400"><%= Helpers.user_tz_abbr(assigns) %></span>
          </div>
          <div :for={day <- @visible_days} class={"text-center py-2 border-l border-tymeslot-100 #{Helpers.day_header_class(day)}"}>
            <span :if={@view == :day} class="text-token-sm font-medium hidden sm:inline"><%= Calendar.strftime(day, "%A, %B %-d, %Y") %></span>
            <span :if={@view == :day} class="text-token-sm font-medium sm:hidden"><%= Calendar.strftime(day, "%a %-d") %></span>
            <span :if={@view != :day} class="text-token-sm"><%= Calendar.strftime(day, "%a %-d") %></span>
          </div>
        </div>

        <%!-- Time grid (keyed on view+date to retrigger fade on navigation) --%>
        <div id="calendar-create-zone" phx-hook="CalendarCreate" phx-target={@myself}>
        <div id="calendar-resize-zone" phx-hook="CalendarResize" phx-target={@myself}>
        <div
          id={"calendar-time-grid-#{@view}-#{Date.to_iso8601(@date)}"}
          class="grid relative animate-fade-in"
          style={"grid-template-columns: var(--time-axis) repeat(#{@col_count}, 1fr)"}
        >
          <%!-- Time axis (sticky left) --%>
          <div class="relative sticky left-0 bg-white z-[5] border-r border-tymeslot-100">
            <div :for={hour <- 0..23} class="h-16 border-b border-tymeslot-100 flex items-start justify-end pr-2 pt-0.5">
              <span class="text-token-xs text-tymeslot-400">
                <%= Helpers.format_hour(hour, assigns) %>
              </span>
            </div>
          </div>

          <%!-- Day columns --%>
          <div
            :for={day <- @visible_days}
            class="relative border-l border-tymeslot-100"
            data-day-col={Date.to_iso8601(day)}
            style="min-height: 96rem;"
          >
            <%!-- Hour grid lines --%>
            <div :for={_hour <- 0..23} class="h-16 border-b border-tymeslot-100"></div>
            <%!-- Events --%>
            <div
              :for={{event, col_idx, total_cols} <- elem(Map.get(@day_layouts, day, {[], []}), 0)}
              id={"event-#{event.id}-#{day}"}
              class={"absolute rounded px-1 py-0.5 #{if @view == :day, do: "text-token-sm", else: "text-token-xs"} font-medium text-white overflow-hidden cursor-pointer hover:brightness-90 focus:outline-none focus:ring-2 focus:ring-turquoise-400 focus:ring-offset-1 group #{Helpers.color_for_event(assigns, event)}"}
              style={"top: #{Helpers.top_rem(event.start_at, @user_timezone)}rem; height: #{Helpers.height_rem(event.start_at, event.end_at)}rem; left: #{Helpers.left_pct(col_idx, total_cols)}%; width: calc(#{Helpers.width_pct(total_cols)}% - 2px);"}
              phx-click="show_event"
              phx-value-event-id={event.id}
              phx-target={@myself}
              role="button"
              tabindex="0"
              aria-label={"#{event.summary || "Untitled event"}, #{Helpers.format_display_time_range(event, Helpers.time_format(assigns), @user_timezone)}"}
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
                alt="Tymeslot"
                class="absolute top-0.5 right-0.5 w-3 h-3 opacity-60"
              />
              <%!-- Enlarged invisible resize hit-target for touch; visual handle revealed on hover --%>
              <div data-resize-handle class="absolute bottom-0 left-0 right-0 h-3 cursor-s-resize touch-none" aria-hidden="true">
                <div class="absolute bottom-0 left-0 right-0 h-2 opacity-0 group-hover:opacity-100 bg-black/10 rounded-b"></div>
              </div>
            </div>

            <.overflow_chip
              :for={{overflow_cluster, idx} <- day |> overflow_clusters(elem(Map.get(@day_layouts, day, {[], []}), 1)) |> Enum.with_index()}
              cluster={overflow_cluster}
              day={day}
              user_timezone={@user_timezone}
              key={"overflow-#{day}-#{idx}"}
              myself={@myself}
            />

            <%!-- Current time indicator --%>
            <div
              :if={Date.compare(day, DateTime.to_date(DateTime.shift_zone!(@current_time, @user_timezone))) == :eq}
              id={"current-time-#{day}"}
              class="absolute left-0 right-0 z-20 pointer-events-none"
              style={"top: #{@current_top_rem}rem"}
              aria-hidden="true"
            >
              <div class="h-0.5 bg-red-500 relative">
                <div class="w-2.5 h-2.5 rounded-full bg-red-500 absolute -left-1.5 -top-[0.1875rem]"></div>
              </div>
            </div>
          </div>
        </div>
        </div>
        </div>

        <%!-- "Jump to now" pill (shown by CalendarDrag hook when marker off-screen) --%>
        <button
          id="calendar-jump-to-now"
          type="button"
          phx-click={JS.dispatch("calendar:scroll-to-current", to: "#calendar-drag-zone")}
          class="hidden fixed bottom-6 right-6 z-30 flex items-center gap-1.5 px-3 py-2 rounded-token-full bg-turquoise-600 hover:bg-turquoise-700 text-white text-token-sm font-medium shadow-lg shadow-turquoise-500/30 focus:outline-none focus:ring-2 focus:ring-turquoise-400 focus:ring-offset-2"
        >
          <IconComponents.icon name={:calendar} class="w-4 h-4" />
          Now
        </button>
      </div>
    </div>
    """
  end

  # ---------- All-day cell (with cap + "more" disclosure) ----------

  attr :assigns_ref, :map, required: true
  attr :day, :any, required: true
  attr :myself, :any, required: true

  defp allday_cell(assigns) do
    all_day_events = Helpers.all_day_events_for_day(assigns.assigns_ref, assigns.day)
    {shown, hidden} = Enum.split(all_day_events, @allday_visible_limit)

    assigns =
      assigns
      |> assign(:shown, shown)
      |> assign(:hidden, hidden)
      |> assign(:hidden_count, length(hidden))

    ~H"""
    <details class="group border-l border-tymeslot-100 p-0.5 min-h-[1.5rem] [&>summary::-webkit-details-marker]:hidden">
      <summary class="flex flex-col gap-0.5 list-none cursor-default">
        <div
          :for={event <- @shown}
          class={"rounded px-1 text-token-xs font-medium text-white truncate cursor-pointer #{Helpers.color_for_event(@assigns_ref, event)}"}
          phx-click="show_event"
          phx-value-event-id={event.id}
          phx-target={@myself}
          role="button"
          tabindex="0"
          aria-label={"All-day: #{event.summary || "Untitled event"}"}
          onclick="event.stopPropagation()"
        >
          <img
            :if={Map.get(event, :created_by_tymeslot)}
            src="/images/brand/logo.svg"
            alt=""
            class="inline-block w-3 h-3 opacity-60 mr-0.5 align-text-bottom"
          /><%= event.summary || "(No title)" %>
        </div>
        <span
          :if={@hidden_count > 0}
          class="text-token-xs text-tymeslot-500 hover:text-tymeslot-700 cursor-pointer px-1 group-open:hidden"
        >+<%= @hidden_count %> more</span>
      </summary>
      <div :if={@hidden_count > 0} class="flex flex-col gap-0.5 mt-0.5">
        <div
          :for={event <- @hidden}
          class={"rounded px-1 text-token-xs font-medium text-white truncate cursor-pointer #{Helpers.color_for_event(@assigns_ref, event)}"}
          phx-click="show_event"
          phx-value-event-id={event.id}
          phx-target={@myself}
          role="button"
          tabindex="0"
        ><%= event.summary || "(No title)" %></div>
      </div>
    </details>
    """
  end

  # ---------- Overflow chip (3+ overlapping events) ----------

  attr :cluster, :map, required: true
  attr :day, :any, required: true
  attr :user_timezone, :string, required: true
  attr :key, :string, required: true
  attr :myself, :any, required: true

  defp overflow_chip(assigns) do
    first_event = List.first(assigns.cluster.events)
    first_id = first_event && first_event.id

    assigns = assign(assigns, :first_event_id, first_id)

    ~H"""
    <button
      :if={@first_event_id}
      id={@key}
      type="button"
      phx-click="show_event"
      phx-value-event-id={@first_event_id}
      phx-target={@myself}
      class="absolute right-0.5 z-10 px-1.5 py-0.5 rounded-full bg-tymeslot-900/80 hover:bg-tymeslot-900 text-white text-token-xs font-semibold shadow-sm focus:outline-none focus:ring-2 focus:ring-turquoise-400"
      style={"top: #{Helpers.top_rem(@cluster.start_at, @user_timezone)}rem;"}
      aria-label={"#{length(@cluster.events)} more events"}
    >
      +<%= length(@cluster.events) %>
    </button>
    """
  end

  # Group overflow events into time-contiguous clusters so we can render one chip per cluster.
  defp overflow_clusters(_day, overflow_events) do
    events = Enum.sort_by(overflow_events, & &1.start_at, DateTime)

    events
    |> Enum.reduce([], fn event, clusters ->
      case clusters do
        [] ->
          [%{start_at: event.start_at, end_at: event.end_at, events: [event]}]

        [head | rest] ->
          if DateTime.compare(event.start_at, head.end_at) == :lt do
            updated = %{
              start_at: head.start_at,
              end_at: max_datetime(head.end_at, event.end_at),
              events: [event | head.events]
            }

            [updated | rest]
          else
            [%{start_at: event.start_at, end_at: event.end_at, events: [event]} | clusters]
          end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn cluster -> Map.update!(cluster, :events, &Enum.reverse/1) end)
  end

  defp max_datetime(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp today_in_visible?(visible_days, current_time, timezone) do
    today = current_time |> DateTime.shift_zone!(timezone) |> DateTime.to_date()
    Enum.any?(visible_days, &(Date.compare(&1, today) == :eq))
  end

  # ---------- Month view ----------

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
      <div class="grid border-b border-tymeslot-200 bg-white sticky top-0 z-10"
        style={if Helpers.show_week_numbers?(assigns), do: "grid-template-columns: 2rem repeat(7, 1fr)", else: "grid-template-columns: repeat(7, 1fr)"}>
        <div :if={Helpers.show_week_numbers?(assigns)} class="text-center text-token-xs font-medium text-tymeslot-400 py-1 sm:py-2">Wk</div>
        <div :for={day_name <- Helpers.day_name_headers(assigns)} class="text-center text-token-xs font-medium text-tymeslot-500 py-1 sm:py-2 uppercase tracking-wide">
          <span class="hidden sm:inline"><%= day_name %></span>
          <span class="sm:hidden"><%= String.first(day_name) %></span>
        </div>
      </div>

      <%!-- 6×7 day cells (keyed on date to retrigger fade on navigation) --%>
      <div
        id={"month-grid-#{@date.year}-#{@date.month}"}
        class="grid animate-fade-in"
        style={if Helpers.show_week_numbers?(assigns), do: "grid-template-columns: 2rem repeat(7, 1fr)", else: "grid-template-columns: repeat(7, 1fr)"}
      >
        <%= for {week_days, _week_idx} <- @visible_days |> Enum.chunk_every(7) |> Enum.with_index() do %>
          <div
            :if={Helpers.show_week_numbers?(assigns)}
            class="text-token-xs text-tymeslot-400 flex items-start justify-center pt-1 border-b border-r border-tymeslot-100"
          ><%= Helpers.week_number(List.first(week_days)) %></div>
          <.month_cell
            :for={day <- week_days}
            day={day}
            assigns_ref={assigns}
            user_timezone={@user_timezone}
            myself={@myself}
          />
        <% end %>
      </div>
    </div>
    """
  end

  attr :day, :any, required: true
  attr :assigns_ref, :map, required: true
  attr :user_timezone, :string, required: true
  attr :myself, :any, required: true

  defp month_cell(assigns) do
    day_events = Helpers.day_events(assigns.assigns_ref, assigns.day)

    today =
      DateTime.utc_now() |> DateTime.shift_zone!(assigns.user_timezone) |> DateTime.to_date()

    is_today = Date.compare(assigns.day, today) == :eq
    is_current_month = assigns.day.month == assigns.assigns_ref.date.month

    assigns =
      assigns
      |> assign(:day_events, day_events)
      |> assign(:is_today, is_today)
      |> assign(:is_current_month, is_current_month)

    ~H"""
    <div
      class={"min-h-16 sm:min-h-24 border-b border-r border-tymeslot-100 p-1 cursor-pointer hover:bg-tymeslot-50 focus:outline-none focus:ring-2 focus:ring-turquoise-400 focus:ring-inset #{Helpers.month_cell_class(@day, @assigns_ref)}"}
      phx-click="navigate_to_day"
      phx-value-date={Date.to_iso8601(@day)}
      phx-target={@myself}
      role="button"
      tabindex="0"
      aria-label={Calendar.strftime(@day, "%A, %B %-d") <> ", #{length(@day_events)} events"}
    >
      <div class={"text-token-xs font-medium mb-0.5 #{day_number_class(@is_today, @is_current_month)}"}>
        <%= @day.day %>
      </div>

      <%!-- Desktop: up to 3 event titles --%>
      <div class="hidden sm:block">
        <div
          :for={event <- Enum.take(@day_events, 3)}
          class={"rounded px-1 text-token-xs text-white truncate mb-0.5 cursor-pointer #{Helpers.color_for_event(@assigns_ref, event)}"}
          phx-click="show_event"
          phx-value-event-id={event.id}
          phx-target={@myself}
        >
          <img
            :if={Map.get(event, :created_by_tymeslot)}
            src="/images/brand/logo.svg"
            alt=""
            class="inline-block w-3 h-3 opacity-60 mr-0.5 align-text-bottom"
          /><%= event.summary || "(No title)" %>
        </div>
        <div :if={length(@day_events) > 3} class="text-token-xs text-tymeslot-400 mt-0.5">
          +<%= length(@day_events) - 3 %> more
        </div>
      </div>

      <%!-- Mobile: first title (truncated) + coloured chip with count --%>
      <div class="sm:hidden flex flex-col gap-0.5 mt-0.5">
        <div
          :if={List.first(@day_events)}
          class={"rounded px-1 text-token-2xs text-white truncate #{Helpers.color_for_event(@assigns_ref, List.first(@day_events))}"}
        ><%= List.first(@day_events).summary || "(No title)" %></div>
        <div
          :if={length(@day_events) > 1}
          class="inline-flex items-center gap-0.5 text-token-2xs text-tymeslot-500 leading-none"
        >
          <span :for={event <- @day_events |> Enum.drop(1) |> Enum.take(3)}
            class={"w-1.5 h-1.5 rounded-full #{Helpers.color_for_event(@assigns_ref, event)}"}
          ></span>
          <span :if={length(@day_events) > 4} class="ml-0.5">+<%= length(@day_events) - 4 %></span>
        </div>
      </div>
    </div>
    """
  end

  defp day_number_class(true = _is_today, _is_current_month),
    do:
      "w-5 h-5 rounded-full bg-turquoise-600 text-white flex items-center justify-center text-center"

  defp day_number_class(_is_today, false = _is_current_month), do: "text-tymeslot-300"
  defp day_number_class(_is_today, _is_current_month), do: "text-tymeslot-600"

  # ---------- Status banners ----------

  attr :stale_integrations, :list, required: true
  attr :syncing, :boolean, required: true
  attr :sync_total, :integer, required: true
  attr :sync_completed, :integer, required: true
  attr :oldest_sync_at, :any
  attr :myself, :any, required: true

  defp status_banners(assigns) do
    ~H"""
    <div :if={@stale_integrations != [] and not @syncing} class="flex items-center gap-2 px-3 py-1.5 md:px-4 bg-amber-50 border-b border-amber-200 text-token-sm text-amber-700">
      <.icon name="hero-exclamation-triangle" class="w-4 h-4 flex-shrink-0" />
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
