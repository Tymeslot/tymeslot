defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.MonthView do
  @moduledoc "Month grid view function component for the calendar grid."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.CalendarGrid.Views.EventBadges

  attr :view, :atom, required: true
  attr :visible_days, :list, required: true
  attr :visible_events, :list, required: true
  attr :integrations, :list, required: true
  attr :integration_colors, :map, required: true
  attr :hidden_integration_ids, :list, required: true
  attr :date, :any, required: true
  attr :user_timezone, :string, required: true
  attr :preferences, :any
  attr :guest_rsvp_summaries, :map, default: %{}
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
      class={"min-h-16 sm:min-h-24 border-b border-r border-tymeslot-100 p-1 cursor-pointer hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400 focus:ring-inset #{Helpers.month_cell_class(@day, @assigns_ref)}"}
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
          /><%= event.summary || "(No title)" %><span
            :if={EventBadges.guest_summary_for_event(@assigns_ref.guest_rsvp_summaries, event)}
            class={["inline-block w-1.5 h-1.5 rounded-full ml-0.5 align-middle", EventBadges.guest_dot_tone(EventBadges.guest_summary_for_event(@assigns_ref.guest_rsvp_summaries, event))]}
            title={EventBadges.guest_badge_title(EventBadges.guest_summary_for_event(@assigns_ref.guest_rsvp_summaries, event))}
          ></span>
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
end
