defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.AgendaView do
  @moduledoc """
  Agenda (schedule list) view for the calendar grid: a vertical, scrollable list
  of upcoming events grouped by day. Each day with at least one event renders a
  date header followed by event rows (time or "All day", title, calendar colour
  dot, and any location). Days without events are skipped; a friendly empty state
  is shown when the whole window holds nothing.
  """

  use TymeslotWeb, :html

  alias TymeslotWeb.Components.Icons.IconComponents
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  attr :view, :atom, required: true
  attr :visible_days, :list, required: true
  attr :visible_events, :list, required: true
  attr :integration_colors, :map, required: true
  attr :user_timezone, :string, required: true
  attr :preferences, :any
  attr :myself, :any, required: true

  @spec agenda_view(map()) :: Phoenix.LiveView.Rendered.t()
  def agenda_view(assigns) do
    assigns = assign(assigns, :groups, day_groups(assigns))

    ~H"""
    <div
      id="calendar-agenda"
      class={if @view == :agenda, do: "flex-1 overflow-y-auto bg-white", else: "hidden"}
    >
      <div :if={@groups == []} class="flex flex-col items-center justify-center h-full px-6 py-16 text-center">
        <div class="w-16 h-16 bg-tymeslot-50 rounded-token-2xl flex items-center justify-center mb-4 border-2 border-dashed border-tymeslot-100">
          <IconComponents.icon name={:calendar} class="w-8 h-8 text-tymeslot-300" />
        </div>
        <h2 class="text-token-lg font-bold text-tymeslot-800 mb-1">No upcoming events</h2>
        <p class="text-token-sm text-tymeslot-500 max-w-sm">
          Nothing scheduled in the next 30 days. Events you add or sync will appear here.
        </p>
      </div>

      <ol :if={@groups != []} class="divide-y divide-tymeslot-100 animate-fade-in">
        <li :for={group <- @groups} class="px-3 md:px-4 py-3">
          <h3 class={"text-token-sm font-semibold mb-2 #{Helpers.day_header_class(group.date, @user_timezone)}"}>
            <%= Calendar.strftime(group.date, "%a %-d %B") %>
          </h3>
          <ul class="flex flex-col gap-1">
            <li
              :for={event <- group.events}
              id={"agenda-event-#{event.id}"}
              class="flex items-start gap-3 rounded-token-md px-2 py-2 cursor-pointer hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
              phx-click="show_event"
              phx-value-event-id={event.id}
              phx-target={@myself}
              role="button"
              tabindex="0"
              aria-label={"#{event.summary || "Untitled event"}, #{time_label(event, @user_timezone, @preferences)}"}
            >
              <span
                class={"mt-0.5 w-2.5 h-2.5 rounded-full shrink-0 #{Helpers.color_for_event(assigns, event)}"}
                aria-hidden="true"
              >
              </span>
              <span class="w-28 md:w-32 shrink-0 text-token-xs text-tymeslot-500 tabular-nums pt-0.5">
                <%= time_label(event, @user_timezone, @preferences) %>
              </span>
              <span class="min-w-0 flex-1">
                <span class="block text-token-sm font-medium text-tymeslot-800 truncate">
                  <%= event.summary || "(No title)" %>
                </span>
                <span
                  :if={event.location not in [nil, ""]}
                  class="mt-0.5 flex items-center gap-1 text-token-xs text-tymeslot-500"
                >
                  <.icon name="hero-map-pin-micro" class="w-3 h-3 shrink-0" />
                  <span class="truncate"><%= event.location %></span>
                </span>
              </span>
            </li>
          </ul>
        </li>
      </ol>
    </div>
    """
  end

  # Builds the ordered list of `%{date, events}` groups for the agenda window,
  # skipping days with no events. All-day events sort first within a day, then
  # timed events by start time.
  defp day_groups(assigns) do
    assigns.visible_days
    |> Enum.map(fn date -> %{date: date, events: events_for_day(assigns, date)} end)
    |> Enum.reject(&(&1.events == []))
  end

  defp events_for_day(assigns, date) do
    all_day =
      assigns
      |> Helpers.all_day_events_for_day(date)
      |> Enum.sort_by(&{&1.summary || "", &1.id})

    timed = assigns |> Helpers.day_events(date) |> Enum.sort_by(& &1.start_at, DateTime)
    all_day ++ timed
  end

  defp time_label(%{all_day: true}, _tz, _prefs), do: "All day"

  defp time_label(event, tz, prefs) do
    Helpers.format_time_range_in_tz(event, tz, Helpers.time_format(prefs))
  end
end
