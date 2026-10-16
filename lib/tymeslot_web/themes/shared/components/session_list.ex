defmodule TymeslotWeb.Themes.Shared.Components.SessionList do
  @moduledoc """
  The dates of a fixed-date meeting type on its booking page
  (`Tymeslot.MeetingTypes.FixedDates`): every upcoming session its host
  planned, with its seats and when registration closes.

  A session open for registration selects its date, as a day in the
  calendar does, so the booker carries on with the time and the form as for
  any group type. A session that is full, or whose registration has closed,
  is listed but cannot be chosen. With nothing left to choose the calendar
  is not shown at all (`show_calendar?/1`), and the list says why: the
  event has ended, registration is closed, or no dates are planned yet.

  `load/3` is what the page assigns as `:planned_sessions`, once per
  availability fetch rather than per render; it is `nil` for every other
  type, which renders nothing. The markup is theme-neutral, styled by each
  theme's own `group-session.css`, as `GroupSession` is.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.{PlannedSessions, Seats}
  alias Tymeslot.MeetingTypes.FixedDates
  alias TymeslotWeb.Themes.Shared.Components.SeatBadge
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @type entry :: %{
          date: String.t(),
          time: String.t(),
          starts_at: DateTime.t(),
          closes_at: DateTime.t() | nil,
          seats_left: non_neg_integer(),
          capacity: pos_integer(),
          seats: Seats.display(),
          open?: boolean()
        }

  @type t :: %{entries: [entry()], ended?: boolean()}

  @doc """
  The upcoming sessions of `meeting_type` as the list shows them, in
  `timezone`, and whether the type has had sessions that are all over.
  `nil` when the type does not use fixed dates.
  """
  @spec load(map() | nil, String.t(), DateTime.t()) :: t() | nil
  def load(meeting_type, timezone, now \\ Clock.utc_now()) do
    if FixedDates.enabled?(meeting_type) do
      entries =
        meeting_type
        |> PlannedSessions.upcoming(now)
        |> Enum.map(&entry(&1, meeting_type, timezone, now))

      %{entries: entries, ended?: entries == [] and PlannedSessions.list(meeting_type) != []}
    end
  end

  # `seats` is what the type's spots display shows for the session, as for
  # any group slot (`SeatBadge.display/2`).
  defp entry(session, meeting_type, timezone, now) do
    local = DateTime.shift_zone!(session.start_time, timezone)
    seats_left = Seats.seats_left(session, session.capacity)

    %{
      date: local |> DateTime.to_date() |> Date.to_iso8601(),
      time: TimeSlots.format_datetime_slot(local),
      starts_at: session.start_time,
      closes_at: session.registration_closes_at,
      seats_left: seats_left,
      capacity: session.capacity,
      seats:
        SeatBadge.display(%{seats_left: seats_left, capacity: session.capacity}, meeting_type),
      open?: seats_left > 0 and PlannedSessions.open?(session, now)
    }
  end

  @doc "Whether the page shows its calendar: always, unless a session list has nothing open."
  @spec show_calendar?(t() | nil) :: boolean()
  def show_calendar?(nil), do: true
  def show_calendar?(%{entries: entries}), do: Enum.any?(entries, & &1.open?)

  attr :sessions, :map, default: nil, doc: "`load/3`'s answer"
  attr :selected_date, :string, default: nil
  attr :timezone, :string, required: true
  attr :target, :any, default: nil
  attr :class, :string, default: nil

  @doc "The list of a fixed-date type's sessions; nothing for any other type."
  @spec session_list(map()) :: Phoenix.LiveView.Rendered.t()
  def session_list(%{sessions: nil} = assigns), do: ~H""

  def session_list(assigns) do
    ~H"""
    <section class={["session-list", @class]} data-testid="session-list">
      <h3 class="session-list-title">{dgettext("booking_sessions", "Dates")}</h3>

      <p
        :if={@sessions.entries == []}
        class="session-list-notice"
        role="status"
        data-testid="sessions-none"
      >
        <%= if @sessions.ended? do %>
          {dgettext("booking_sessions", "This event has ended.")}
        <% else %>
          {dgettext("booking_sessions", "No dates are planned at the moment.")}
        <% end %>
      </p>

      <p
        :if={@sessions.entries != [] and not show_calendar?(@sessions)}
        class="session-list-notice"
        role="status"
        data-testid="registration-closed"
      >
        {dgettext("booking_sessions", "Registration is closed.")}
      </p>

      <ul :if={@sessions.entries != []} class="session-list-items">
        <li :for={entry <- @sessions.entries}>
          <button
            type="button"
            class={["session-list-item", entry.date == @selected_date && "is-selected"]}
            disabled={not entry.open?}
            aria-pressed={to_string(entry.date == @selected_date)}
            phx-click="select_date"
            phx-value-date={entry.date}
            phx-target={@target}
            data-testid="session-entry"
          >
            <span class="session-list-when">
              {LocalizationHelpers.format_meeting_datetime_compact(entry.starts_at, @timezone)}
            </span>
            <SeatBadge.seat_badge :if={entry.open?} display={entry.seats} />
            <span class="session-list-status">{status(entry, @timezone)}</span>
          </button>
        </li>
      </ul>
    </section>
    """
  end

  defp status(%{seats_left: 0}, _timezone), do: dgettext("booking_sessions", "Fully booked")

  defp status(%{open?: false}, _timezone), do: dgettext("booking_sessions", "Registration closed")

  defp status(%{closes_at: %DateTime{} = closes_at}, timezone),
    do:
      dgettext("booking_sessions", "Registration until %{datetime}",
        datetime: LocalizationHelpers.format_meeting_datetime_compact(closes_at, timezone)
      )

  defp status(_entry, _timezone), do: nil
end
