defmodule TymeslotWeb.Dashboard.MeetingSettings.EventsListComponent do
  @moduledoc """
  The meeting settings page's list of one-off events
  (`Tymeslot.MeetingTypes.OneOffEvents`), apart from the host's regular
  meeting types.

  Each event shows when it takes place, the seats taken, where it stands
  (open, registration closed, over, or cancelled) and its booking link to
  copy, with the same edit and delete actions as a meeting type card.
  Upcoming events come first, soonest first; past ones follow, latest first.

  `rows/1` is what the settings component assigns, once per load rather
  than per render.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.{PlannedSessions, Seats}
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.OneOffEvents
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Dashboard.DashboardFormat
  alias TymeslotWeb.Dashboard.MeetingSettings.Card

  @type row :: %{
          type: map(),
          starts_at: DateTime.t() | nil,
          seats_taken: non_neg_integer(),
          capacity: pos_integer(),
          status: :open | :closed | :over | :cancelled
        }

  @doc "The one-off events among `meeting_types`, as the list shows them."
  @spec rows([map()]) :: [row()]
  def rows(meeting_types) do
    now = Clock.utc_now()
    events = Enum.filter(meeting_types, &OneOffEvents.one_off?/1)
    sessions = PlannedSessions.list_by_type(events)

    seats =
      sessions
      |> Enum.flat_map(fn {_type_id, list} -> Enum.take(list, 1) end)
      |> Enum.map(& &1.id)
      |> Seats.counts_by_meeting()

    {upcoming, rest} =
      events
      |> Enum.map(&row(&1, sessions[&1.id], seats, now))
      |> Enum.split_with(&(&1.status in [:open, :closed]))

    Enum.sort_by(upcoming, & &1.starts_at, DateTime) ++
      Enum.sort_by(rest, &(&1.starts_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
  end

  defp row(type, sessions, seats, now) do
    case sessions do
      [session | _rest] ->
        %{
          type: type,
          starts_at: session.start_time,
          seats_taken: seats[session.id].seats_taken,
          capacity: session.capacity,
          status: status(session, now)
        }

      [] ->
        %{
          type: type,
          starts_at: nil,
          seats_taken: 0,
          capacity: type.max_participants,
          status: :cancelled
        }
    end
  end

  defp status(session, now) do
    cond do
      DateTime.compare(session.start_time, now) != :gt -> :over
      PlannedSessions.open?(session, now) -> :open
      true -> :closed
    end
  end

  attr :events, :list, required: true, doc: "`rows/1`"
  attr :booking_base_url, :string, default: nil
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :venues, :list, default: [], doc: "the host's saved venues, to name an event's location"
  attr :parent_myself, :any, required: true

  @spec events_section(map()) :: Phoenix.LiveView.Rendered.t()
  def events_section(%{events: []} = assigns), do: ~H""

  def events_section(assigns) do
    ~H"""
    <section class="space-y-3" data-testid="events-section">
      <.subsection_header
        icon="hero-ticket"
        title={dgettext("dashboard_meeting_types", "Events")}
        description={
          dgettext(
            "dashboard_meeting_types",
            "One-off events created from Quick Add. Each has its own booking link and ends on its own once it is over."
          )
        }
      />

      <.card
        :for={event <- @events}
        padding={:xs}
        class={
          if(event.status in [:open, :closed],
            do: "card-glass-available",
            else: "card-glass-unavailable"
          )
        }
        data-testid="event-row"
      >
        <div class="flex items-center gap-3">
          <.icon
            name={event_icon(event.type)}
            class="w-5 h-5 text-tymeslot-600 shrink-0"
          />

          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 min-w-0">
              <h2 class="text-token-lg font-semibold text-tymeslot-900 truncate">
                {event.type.name}
              </h2>
              <.pill tone={tone(event.status)}>{label(event.status)}</.pill>
            </div>
            <div class="flex flex-wrap items-center gap-x-3 gap-y-0.5 mt-0.5 text-token-xs text-tymeslot-600">
              <span :if={event.starts_at} class="flex items-center shrink-0">
                <.icon name="hero-calendar-days-mini" class="w-3.5 h-3.5 mr-1 text-tymeslot-500" />
                {when_label(event.starts_at, @timezone, @time_format)}
              </span>
              <span class="flex items-center shrink-0">
                <.icon name="hero-clock" class="w-3.5 h-3.5 mr-1" />
                {dgettext("dashboard_meeting_types", "%{minutes} min",
                  minutes: event.type.duration_minutes
                )}
              </span>
              <span class="flex items-center shrink-0">
                <.icon name="hero-users-mini" class="w-3.5 h-3.5 mr-1 text-tymeslot-500" />
                {dgettext("dashboard_meeting_types", "%{count}/%{capacity} seats taken",
                  count: event.seats_taken,
                  capacity: event.capacity
                )}
              </span>
              <Card.location_summary type={event.type} icon_size="mini" venues={@venues} />
            </div>
          </div>

          <%!-- Actions, named after the event as on a meeting type card. --%>
          <div class="flex items-center gap-2 shrink-0">
            <Buttons.icon_button
              :if={@booking_base_url && event.status in [:open, :closed]}
              icon="hero-link"
              size={:sm}
              id={"copy-event-link-#{event.type.id}"}
              label={dgettext("dashboard_meeting_types", "Copy link")}
              tooltip={dgettext("dashboard_meeting_types", "Copy link")}
              phx-hook="CopyOnClick"
              data-copy-text={"#{@booking_base_url}/#{MeetingTypes.effective_slug(event.type)}"}
              data-copy-feedback={dgettext("dashboard_meeting_types", "Booking link copied!")}
            />
            <Buttons.icon_button
              icon="hero-pencil-square"
              size={:sm}
              label={dgettext("dashboard_meeting_types", "Edit %{name}", name: event.type.name)}
              tooltip={dgettext("dashboard_meeting_types", "Edit")}
              phx-click="edit_type"
              phx-value-id={event.type.id}
              phx-target={@parent_myself}
            />
            <Buttons.icon_button
              icon="hero-trash"
              variant={:danger}
              size={:sm}
              label={dgettext("dashboard_meeting_types", "Delete %{name}", name: event.type.name)}
              tooltip={dgettext("dashboard_meeting_types", "Delete")}
              phx-click="show_delete_modal"
              phx-value-id={event.type.id}
              phx-target={@parent_myself}
            />
          </div>
        </div>
      </.card>
    </section>
    """
  end

  defp when_label(starts_at, timezone, time_format) do
    date = starts_at |> DashboardFormat.local_date(timezone) |> DashboardFormat.long_date()
    "#{date}, #{DashboardFormat.clock(starts_at, timezone, time_format)}"
  end

  # An event shows the icon its type was given, as a meeting type card does,
  # or the events section's own when it has none.
  defp event_icon(%{icon: icon}) when is_binary(icon) and icon != "none", do: icon
  defp event_icon(_type), do: "hero-ticket"

  defp tone(:open), do: :success
  defp tone(:closed), do: :warning
  defp tone(_over_or_cancelled), do: :neutral

  defp label(:open), do: dgettext("dashboard_meeting_types", "Registration open")
  defp label(:closed), do: dgettext("dashboard_meeting_types", "Registration closed")
  defp label(:over), do: dgettext("dashboard_meeting_types", "Over")
  defp label(:cancelled), do: dgettext("dashboard_meeting_types", "Cancelled")
end
