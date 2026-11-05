defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.AllDayRow do
  @moduledoc "All-day cell function component for the calendar grid week/day view."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.DashboardFormat

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
    <%!-- A disclosure only when opening it reveals something: an empty or
          fully shown day as a <details> would be an unnamed toggle that does
          nothing, which screen readers announce as "button, collapsed". --%>
    <details
      :if={@hidden_count > 0}
      class="group border-l border-tymeslot-200 p-0.5 min-h-[1.5rem] [&>summary::-webkit-details-marker]:hidden"
    >
      <summary class="flex flex-col gap-0.5 list-none cursor-default">
        <.shown_chip
          :for={event <- @shown}
          event={event}
          day={@day}
          assigns_ref={@assigns_ref}
          myself={@myself}
          in_summary
        />
        <span class="text-token-xs text-tymeslot-500 hover:text-tymeslot-700 cursor-pointer px-1 group-open:hidden">{dngettext(
          "dashboard_calendar",
          "+%{count} more",
          "+%{count} more",
          @hidden_count,
          count: @hidden_count
        )}</span>
      </summary>
      <div class="flex flex-col gap-0.5 mt-0.5">
        <div
          :for={event <- @hidden}
          class={"rounded px-1 text-token-xs font-medium text-white truncate cursor-pointer #{Helpers.color_for_event(@assigns_ref, event)}"}
          {Helpers.open_event_attrs(event, keys: :hook, target: @myself)}
        >
          {DashboardFormat.title(event.summary)}
        </div>
      </div>
    </details>
    <div
      :if={@hidden_count == 0}
      class="flex flex-col gap-0.5 border-l border-tymeslot-200 p-0.5 min-h-[1.5rem]"
    >
      <.shown_chip
        :for={event <- @shown}
        event={event}
        day={@day}
        assigns_ref={@assigns_ref}
        myself={@myself}
      />
    </div>
    """
  end

  attr :event, :map, required: true
  attr :day, :any, required: true
  attr :assigns_ref, :map, required: true
  attr :myself, :any, required: true

  attr :in_summary, :boolean,
    default: false,
    doc: "Inside a <summary>, a click must open the event, not toggle the row."

  defp shown_chip(assigns) do
    ~H"""
    <%!-- An all-day event covering several days is rendered in each of
          its cells, so the id names the day as well. --%>
    <div
      id={"allday-event-#{@event.id}-#{@day}"}
      phx-hook={@in_summary && "PreventSummaryToggle"}
      class={"rounded px-1 text-token-xs font-medium text-white truncate cursor-pointer #{Helpers.color_for_event(@assigns_ref, @event)}"}
      {Helpers.open_event_attrs(@event, keys: :hook, target: @myself)}
      aria-label={
        dgettext("dashboard_calendar", "All-day: %{event}",
          event: DashboardFormat.title(@event.summary)
        )
      }
    >
      <img
        :if={Map.get(@event, :created_by_tymeslot)}
        src="/images/brand/logo.svg"
        alt=""
        class="inline-block w-3 h-3 opacity-60 mr-0.5 align-text-bottom"
      /><.icon
        :if={(Map.get(@event, :reminders) || []) != []}
        name="hero-bell-micro"
        class="inline-block w-3 h-3 opacity-70 mr-0.5 align-text-bottom"
      />{DashboardFormat.title(@event.summary)}
    </div>
    """
  end
end
