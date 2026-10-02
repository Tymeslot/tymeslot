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

  alias Tymeslot.Agenda
  alias TymeslotWeb.Components.Dashboard.Appointments.AppointmentRow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers
  alias TymeslotWeb.Dashboard.DashboardFormat

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
    assigns = assign(assigns, :groups, day_groups(assigns))

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

      <.empty_state
        :if={@groups == []}
        icon="hero-calendar-days"
        variant={:plain}
        heading={:h2}
        class="flex flex-col items-center justify-center h-full"
        title={
          if @agenda_lens == :bookings,
            do: dgettext("dashboard_calendar", "No upcoming bookings"),
            else: dgettext("dashboard_calendar", "No upcoming events")
        }
        description={
          if @agenda_lens == :bookings,
            do:
              dgettext(
                "dashboard_calendar",
                "Meetings booked through your Tymeslot page will appear here."
              ),
            else:
              dgettext(
                "dashboard_calendar",
                "Nothing scheduled in the next 30 days. Events you add or sync will appear here."
              )
        }
      />

      <ol :if={@groups != []} class="divide-y divide-tymeslot-100 animate-fade-in">
        <li :for={group <- @groups} class="px-3 md:px-4 py-3">
          <h3 class={"text-token-sm font-semibold mb-2 #{Helpers.day_header_class(group.date, @user_timezone)}"}>
            {DashboardFormat.short_date(group.date)}
          </h3>
          <ul class="flex flex-col gap-1">
            <%!-- An event spanning midnight or several days is listed under
                  each of its days, so the id names the day as well. --%>
            <AppointmentRow.appointment_row
              :for={row <- group.rows}
              id={"agenda-event-#{row.event.id}-#{Date.to_iso8601(group.date)}"}
              variant={:list}
              entry={row.entry}
              on_open={Helpers.open_event_attrs(row.event, keys: :hook, target: @myself)}
              colour_class={Helpers.color_for_event(assigns, row.event)}
              timezone={@user_timezone}
              time_format={Helpers.time_format(@preferences)}
            />
          </ul>
        </li>
      </ol>
    </div>
    """
  end

  # Builds the ordered list of `%{date, rows}` groups for the agenda window,
  # skipping days with no events. All-day events sort first within a day, then
  # timed events by start time. Each row keeps the grid event, which decides
  # its colour and the modal it opens, beside the entry it renders.
  defp day_groups(assigns) do
    assigns.visible_days
    |> Enum.map(fn date -> %{date: date, rows: rows_for_day(assigns, date)} end)
    |> Enum.reject(&(&1.rows == []))
  end

  defp rows_for_day(assigns, date) do
    assigns
    |> events_for_day(date)
    |> Enum.map(&%{event: &1, entry: Agenda.entry_for_grid_event(&1, assigns.user_timezone)})
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
end
