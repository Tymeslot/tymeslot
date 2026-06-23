defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.AllDayRow do
  @moduledoc "All-day cell function component for the calendar grid week/day view."

  use TymeslotWeb, :html

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @allday_visible_limit 2

  # ---------- All-day cell (with cap + "more" disclosure) ----------

  attr :assigns_ref, :map, required: true
  attr :day, :any, required: true
  attr :myself, :any, required: true

  @spec all_day_cell(map()) :: Phoenix.LiveView.Rendered.t()
  def all_day_cell(assigns) do
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
          id={"allday-event-#{event.id}"}
          phx-hook="StopClickPropagation"
          class={"rounded px-1 text-token-xs font-medium text-white truncate cursor-pointer #{Helpers.color_for_event(@assigns_ref, event)}"}
          phx-click="show_event"
          phx-value-event-id={event.id}
          phx-target={@myself}
          role="button"
          tabindex="0"
          aria-label={"All-day: #{event.summary || "Untitled event"}"}
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
end
