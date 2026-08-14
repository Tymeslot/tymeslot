defmodule TymeslotWeb.Dashboard.CalendarGrid.Views.AgendaView do
  @moduledoc """
  Agenda (schedule list) view for the calendar grid: a vertical, scrollable list
  of upcoming events grouped by day. Each day with at least one event renders a
  date header followed by event rows (time or "All day", title, calendar colour
  dot, and any location). Days without events are skipped; a friendly empty state
  is shown when the whole window holds nothing.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Helpers.LocaleFormat

  attr :view, :atom, required: true
  attr :visible_days, :list, required: true
  attr :visible_events, :list, required: true
  attr :integration_colors, :map, required: true
  attr :calendar_colors, :map, required: true
  attr :user_timezone, :string, required: true
  attr :preferences, :any
  attr :agenda_lens, :atom, default: :all
  attr :myself, :any, required: true

  @spec agenda_view(map()) :: Phoenix.LiveView.Rendered.t()
  def agenda_view(assigns) do
    assigns =
      assigns
      |> assign(:groups, day_groups(assigns))
      |> assign(:locale, Gettext.get_locale(TymeslotWeb.Gettext))

    ~H"""
    <div
      id="calendar-agenda"
      class={if @view == :agenda, do: "flex-1 overflow-y-auto bg-white", else: "hidden"}
    >
      <%!-- Lens: everything, or only Tymeslot bookings --%>
      <div class="sticky top-0 z-10 bg-white px-3 md:px-4 py-2 border-b border-tymeslot-100">
        <div
          class="inline-flex rounded-token-lg border border-tymeslot-200 p-0.5 gap-0.5"
          role="tablist"
          aria-label={dgettext("dashboard_calendar", "Filter agenda")}
        >
          <button
            type="button"
            role="tab"
            aria-selected={to_string(@agenda_lens == :all)}
            phx-click="set_agenda_lens"
            phx-value-lens="all"
            phx-target={@myself}
            data-testid="agenda-lens-all"
            class={"px-3 py-1 rounded-token-md text-token-xs font-semibold transition-colors #{if @agenda_lens == :all, do: "bg-turquoise-600 text-white shadow-sm", else: "text-tymeslot-600 hover:bg-tymeslot-50"}"}
          >
            {dgettext("dashboard_calendar", "All")}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={to_string(@agenda_lens == :bookings)}
            phx-click="set_agenda_lens"
            phx-value-lens="bookings"
            phx-target={@myself}
            data-testid="agenda-lens-bookings"
            class={"px-3 py-1 rounded-token-md text-token-xs font-semibold transition-colors #{if @agenda_lens == :bookings, do: "bg-turquoise-600 text-white shadow-sm", else: "text-tymeslot-600 hover:bg-tymeslot-50"}"}
          >
            {dgettext("dashboard_calendar", "Bookings")}
          </button>
        </div>
      </div>

      <div
        :if={@groups == []}
        class="flex flex-col items-center justify-center h-full px-6 py-16 text-center"
      >
        <div class="w-16 h-16 bg-tymeslot-50 rounded-token-2xl flex items-center justify-center mb-4 border-2 border-dashed border-tymeslot-100">
          <.icon name="hero-calendar-days" class="w-8 h-8 text-tymeslot-300" />
        </div>
        <h2 class="text-token-lg font-bold text-tymeslot-800 mb-1">
          {if @agenda_lens == :bookings,
            do: dgettext("dashboard_calendar", "No upcoming bookings"),
            else: dgettext("dashboard_calendar", "No upcoming events")}
        </h2>
        <p class="text-token-sm text-tymeslot-500 max-w-sm">
          {if @agenda_lens == :bookings,
            do:
              dgettext(
                "dashboard_calendar",
                "Meetings booked through your Tymeslot page will appear here."
              ),
            else:
              dgettext(
                "dashboard_calendar",
                "Nothing scheduled in the next 30 days. Events you add or sync will appear here."
              )}
        </p>
      </div>

      <ol :if={@groups != []} class="divide-y divide-tymeslot-100 animate-fade-in">
        <li :for={group <- @groups} class="px-3 md:px-4 py-3">
          <h3 class={"text-token-sm font-semibold mb-2 #{Helpers.day_header_class(group.date, @user_timezone)}"}>
            {"#{LocaleFormat.format_weekday_name(Date.day_of_week(group.date), @locale, :short)} #{group.date.day} #{LocaleFormat.format_month_name(group.date.month, @locale)}"}
          </h3>
          <ul class="flex flex-col gap-1">
            <li
              :for={event <- group.events}
              id={"agenda-event-#{event.id}"}
              class="flex items-start gap-3 rounded-token-md px-2 py-2 cursor-pointer hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
              {Helpers.open_event_attrs(event)}
              phx-target={@myself}
              role="button"
              tabindex="0"
              aria-label={
                dgettext("dashboard_calendar", "%{event}, %{time}",
                  event: event.summary || dgettext("dashboard_calendar", "Untitled event"),
                  time: time_label(event, @user_timezone, @preferences)
                )
              }
            >
              <span
                class={"mt-0.5 w-2.5 h-2.5 rounded-full shrink-0 #{Helpers.color_for_event(assigns, event)}"}
                aria-hidden="true"
              ></span>
              <span class="w-28 md:w-32 shrink-0 text-token-xs text-tymeslot-500 tabular-nums pt-0.5">
                {time_label(event, @user_timezone, @preferences)}
              </span>
              <span class="min-w-0 flex-1">
                <span class="block text-token-sm font-medium text-tymeslot-800 truncate">
                  {event.summary || dgettext("dashboard_calendar", "(No title)")}
                </span>
                <span
                  :if={event.location not in [nil, ""]}
                  class="mt-0.5 flex items-center gap-1 text-token-xs text-tymeslot-500"
                >
                  <.icon name="hero-map-pin-micro" class="w-3 h-3 shrink-0" />
                  <span class="truncate">{event.location}</span>
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
    apply_lens(all_day ++ timed, assigns.agenda_lens)
  end

  # The bookings lens keeps Tymeslot-originated entries only: native booking
  # projections plus their provider-synced copies (`created_by_tymeslot`).
  defp apply_lens(events, :bookings),
    do: Enum.filter(events, &(Helpers.booking?(&1) or Map.get(&1, :created_by_tymeslot)))

  defp apply_lens(events, _lens), do: events

  defp time_label(%{all_day: true}, _tz, _prefs), do: dgettext("dashboard_calendar", "All day")

  defp time_label(event, tz, prefs) do
    Helpers.format_time_range_in_tz(event, tz, Helpers.time_format(prefs))
  end
end
