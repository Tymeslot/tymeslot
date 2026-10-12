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

    {upcoming, rest} =
      meeting_types
      |> Enum.filter(&OneOffEvents.one_off?/1)
      |> Enum.map(&row(&1, now))
      |> Enum.split_with(&(&1.status in [:open, :closed]))

    Enum.sort_by(upcoming, & &1.starts_at, DateTime) ++
      Enum.sort_by(rest, &(&1.starts_at || ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
  end

  defp row(type, now) do
    case PlannedSessions.list(type) do
      [session | _rest] ->
        %{
          type: type,
          starts_at: session.start_time,
          seats_taken: Seats.seats_taken(session.id),
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

      <.card :for={event <- @events} variant={:flat} data-testid="event-row">
        <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
          <div class="min-w-0 flex-1 space-y-1">
            <div class="flex flex-wrap items-center gap-2">
              <h3 class="font-semibold text-tymeslot-900">{event.type.name}</h3>
              <.pill tone={tone(event.status)} size={:xs}>{label(event.status)}</.pill>
            </div>
            <p class="text-token-sm text-tymeslot-600">
              <span :if={event.starts_at}>
                {when_label(event.starts_at, @timezone, @time_format)} ·
              </span>
              {dgettext("dashboard_meeting_types", "%{count}/%{capacity} seats taken",
                count: event.seats_taken,
                capacity: event.capacity
              )}
            </p>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <.action_button
              :if={@booking_base_url && event.status in [:open, :closed]}
              size={:sm}
              variant={:secondary}
              id={"copy-event-link-#{event.type.id}"}
              phx-hook="CopyOnClick"
              data-copy-text={"#{@booking_base_url}/#{MeetingTypes.effective_slug(event.type)}"}
              data-copy-feedback={dgettext("dashboard_meeting_types", "Booking link copied!")}
            >
              {dgettext("dashboard_meeting_types", "Copy link")}
            </.action_button>
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

  defp tone(:open), do: :success
  defp tone(:closed), do: :warning
  defp tone(_over_or_cancelled), do: :neutral

  defp label(:open), do: dgettext("dashboard_meeting_types", "Registration open")
  defp label(:closed), do: dgettext("dashboard_meeting_types", "Registration closed")
  defp label(:over), do: dgettext("dashboard_meeting_types", "Over")
  defp label(:cancelled), do: dgettext("dashboard_meeting_types", "Cancelled")
end
