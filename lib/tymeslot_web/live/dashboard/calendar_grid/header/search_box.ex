defmodule TymeslotWeb.Dashboard.CalendarGrid.Header.SearchBox do
  @moduledoc """
  Event search box for the calendar grid toolbar.

  Typing debounces a `search` event to the server, which returns matching cached
  events; results drop below the input and close on selection, Escape, or a click
  outside. The `#calendar-search-input` id lets the `/` shortcut focus the box.
  """

  use TymeslotWeb, :html

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  attr :search_term, :string, required: true
  attr :search_results, :list, required: true
  attr :search_open, :boolean, required: true
  attr :user_timezone, :string, required: true
  attr :preferences, :any, required: true
  attr :integration_colors, :map, required: true
  attr :myself, :any, required: true

  @spec search_box(map()) :: Phoenix.LiveView.Rendered.t()
  def search_box(assigns) do
    ~H"""
    <%!--
      Event search. Typing debounces a `search` event to the server, which
      returns matching cached events. The results panel drops below the input;
      it closes on selection, Escape, or a click outside (phx-click-away).
      The `#calendar-search-input` id lets the `/` shortcut focus this box.
    --%>
    <div
      class="relative hidden sm:flex items-center"
      phx-click-away={@search_open && JS.push("close_search", target: @myself)}
    >
      <div class="relative">
        <span class="pointer-events-none absolute inset-y-0 left-2 flex items-center text-tymeslot-400">
          <.icon name="hero-magnifying-glass-mini" class="w-4 h-4" />
        </span>
        <input
          id="calendar-search-input"
          type="text"
          name="term"
          value={@search_term}
          autocomplete="off"
          placeholder="Search events"
          aria-label="Search events"
          phx-keyup="search"
          phx-debounce="300"
          phx-target={@myself}
          class="w-40 lg:w-52 pl-8 pr-2 py-1.5 text-token-sm text-tymeslot-700 placeholder:text-tymeslot-400 border border-tymeslot-200 rounded-md focus:outline-hidden focus:ring-2 focus:ring-turquoise-400 focus:border-turquoise-400"
        />
      </div>
      <div
        :if={@search_open}
        id="calendar-search-results"
        phx-window-keydown={JS.push("close_search", target: @myself)}
        phx-key="Escape"
        class="absolute top-full left-0 mt-1 w-72 max-h-80 overflow-y-auto bg-white border border-tymeslot-200 rounded-xl shadow-lg py-1 z-30"
        role="listbox"
      >
        <button
          :for={event <- @search_results}
          type="button"
          phx-click="goto_search_result"
          phx-value-event-id={event.id}
          phx-value-date={result_date_iso(event, @user_timezone)}
          phx-target={@myself}
          class="w-full text-left px-3 py-2 flex items-start gap-2 hover:bg-tymeslot-50 focus:outline-hidden focus:bg-tymeslot-50"
          role="option"
        >
          <span
            class={"mt-1 w-2.5 h-2.5 rounded-full shrink-0 #{Helpers.color_class_for_integration(@integration_colors, event.calendar_integration_id)}"}
            aria-hidden="true"
          >
          </span>
          <span class="min-w-0">
            <span class="block text-token-sm text-tymeslot-800 truncate">
              {event.summary || "Untitled event"}
            </span>
            <span class="block text-token-xs text-tymeslot-500">
              {result_time_label(event, @user_timezone, @preferences)}
            </span>
          </span>
        </button>
        <p
          :if={@search_results == []}
          class="px-3 py-2 text-token-sm text-tymeslot-400"
        >
          No matching events
        </p>
      </div>
    </div>
    """
  end

  # ISO date used to navigate the grid to the event. All-day events carry a
  # start_date; timed events are resolved into the user's local date.
  defp result_date_iso(%{all_day: true, start_date: %Date{} = date}, _tz),
    do: Date.to_iso8601(date)

  defp result_date_iso(%{start_at: %DateTime{} = start_at}, tz) do
    start_at
    |> DateTime.shift_zone!(tz)
    |> DateTime.to_date()
    |> Date.to_iso8601()
  end

  defp result_date_iso(_event, _tz), do: ""

  # Short "date · time-range" label for a search result row.
  defp result_time_label(%{all_day: true, start_date: %Date{} = date}, _tz, _prefs),
    do: Calendar.strftime(date, "%a %b %-d") <> " · All day"

  defp result_time_label(%{start_at: %DateTime{} = start_at} = event, tz, prefs) do
    fmt = Helpers.time_format(prefs)
    local_date = start_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()

    Calendar.strftime(local_date, "%a %b %-d") <>
      " · " <> Helpers.format_time_range_in_tz(event, tz, fmt)
  end

  defp result_time_label(_event, _tz, _prefs), do: ""
end
