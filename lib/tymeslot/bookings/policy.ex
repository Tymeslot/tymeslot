defmodule Tymeslot.Bookings.Policy do
  @moduledoc """
  The booking rules: whether a meeting can still be cancelled, rescheduled or
  asked to move, and whether a booking may bring guests.

  The verdict predicates read the system clock (`Tymeslot.Clock`) and log
  their blocked branches. The scheduling policy a booking time is checked
  against is `Tymeslot.Availability.Schedules.booking_config/2`. The attributes a booking is written with are assembled by
  `Tymeslot.Bookings.MeetingAttributes`, and its links by
  `Tymeslot.Bookings.MeetingLinks`.
  """
  alias Tymeslot.Clock

  require Logger

  @typedoc "A meeting record with the fields required by the policy checks."
  @type meeting_record :: %{
          required(:status) => String.t(),
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          optional(atom()) => term()
        }

  @doc """
  True when the booking's meeting type allows the booker to add guests.

  Shared by the solo/paid booking transaction and the group seat-booking
  pipeline so both re-apply the same rule to the (never-trusted) client-
  submitted guest list.
  """
  @spec guests_allowed?(map()) :: boolean()
  def guests_allowed?(%{meeting_type: %{allow_guests: true}}), do: true
  def guests_allowed?(_booking_data), do: false

  @typedoc """
  Why a meeting can no longer be changed, by its status or its time. The web
  layer renders a refusal (`TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage`).
  """
  @type meeting_state ::
          :cancelled | :completed | :expired | :awaiting_approval | :started | :past
  @type cancel_refusal :: :already_cancelled | {:not_cancellable, meeting_state()}
  @type reschedule_refusal :: {:not_reschedulable, meeting_state()}

  @doc """
  Determines if a meeting can be cancelled.
  Checks both status and time constraints.
  """
  @spec can_cancel_meeting?(meeting_record()) :: :ok | {:error, cancel_refusal()}
  def can_cancel_meeting?(meeting) do
    cond do
      meeting.status == "cancelled" ->
        {:error, :already_cancelled}

      meeting.status == "completed" ->
        {:error, {:not_cancellable, :completed}}

      # An expired meeting (a lapsed approval request or an abandoned paid
      # checkout) has already been released: its slot was freed, the attendee
      # was told the request lapsed, and `Meetings.Approval` has already
      # refunded whatever was paid for it. Cancelling would overwrite that
      # outcome with `"cancelled"` and run the whole cancellation pipeline
      # over it — a second pair of emails contradicting the expiry notice, a
      # `meeting.cancelled` webhook for a meeting that never happened, and a
      # calendar delete for an event already removed. The request-received
      # email's withdraw link stays live in the invitee's inbox after the
      # deadline, so this is a reachable click, not a theoretical one.
      meeting.status == "expired" ->
        {:error, {:not_cancellable, :expired}}

      meeting_is_current?(meeting) ->
        Logger.info("Blocked cancellation: meeting has already started",
          meeting_id: Map.get(meeting, :id)
        )

        {:error, {:not_cancellable, :started}}

      meeting_is_past?(meeting) ->
        Logger.info("Blocked cancellation: meeting has already occurred",
          meeting_id: Map.get(meeting, :id)
        )

        {:error, {:not_cancellable, :past}}

      true ->
        :ok
    end
  end

  @doc """
  Determines if a meeting can be rescheduled.
  Checks both status and time constraints.
  """
  @spec can_reschedule_meeting?(meeting_record()) :: :ok | {:error, reschedule_refusal()}
  def can_reschedule_meeting?(meeting) do
    cond do
      meeting.status == "cancelled" ->
        {:error, {:not_reschedulable, :cancelled}}

      meeting.status == "completed" ->
        {:error, {:not_reschedulable, :completed}}

      # An expired meeting (a lapsed approval request or an abandoned paid
      # checkout) has already released its slot: `MeetingState`'s
      # `@occupying_statuses` excludes "expired", so conflict detection ignores
      # it. Rescheduling would move it to a new time it does not reserve, and
      # the attendee would be told about a booking anyone else can still take.
      meeting.status == "expired" ->
        {:error, {:not_reschedulable, :expired}}

      meeting_is_current?(meeting) ->
        Logger.info("Blocked reschedule: meeting has already started",
          meeting_id: Map.get(meeting, :id)
        )

        {:error, {:not_reschedulable, :started}}

      meeting_is_past?(meeting) ->
        Logger.info("Blocked reschedule: meeting has already occurred",
          meeting_id: Map.get(meeting, :id)
        )

        {:error, {:not_reschedulable, :past}}

      true ->
        :ok
    end
  end

  @doc """
  Determines if the organiser may ask the attendee to pick a new time
  (`Tymeslot.Bookings.RescheduleRequest`, the host-initiated flow that voids
  the current slot and waits on the attendee).

  Distinct from `can_reschedule_meeting?/1`: that one also gates the
  attendee moving their own booking, including a still-held request, which
  is allowed. This one refuses a held request outright, because the host
  has no reschedule action until they have approved it — voiding the slot
  here would leave a request that still reads as approvable pointing at
  time that no longer holds.
  """
  @spec can_request_reschedule?(meeting_record()) :: :ok | {:error, reschedule_refusal()}
  def can_request_reschedule?(%{status: "awaiting_approval"}) do
    {:error, {:not_reschedulable, :awaiting_approval}}
  end

  def can_request_reschedule?(meeting), do: can_reschedule_meeting?(meeting)

  @doc """
  Checks if a meeting is currently happening.
  Pure function that compares meeting times with current UTC time.
  """
  @spec meeting_is_current?(%{
          required(:start_time) => DateTime.t(),
          required(:end_time) => DateTime.t(),
          optional(atom()) => term()
        }) :: boolean()
  def meeting_is_current?(%{start_time: start_time, end_time: end_time}) do
    now = Clock.utc_now()
    DateTime.compare(start_time, now) != :gt && DateTime.compare(end_time, now) == :gt
  end

  @doc """
  Checks if a meeting is in the past.
  Pure function that compares meeting end time with current UTC time.
  """
  @spec meeting_is_past?(%{required(:end_time) => DateTime.t(), optional(atom()) => term()}) ::
          boolean()
  def meeting_is_past?(%{end_time: end_time}) do
    DateTime.compare(end_time, Clock.utc_now()) == :lt
  end
end
