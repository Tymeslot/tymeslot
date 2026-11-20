defmodule Tymeslot.Bookings.Policy do
  @moduledoc """
  The booking rules: whether a meeting can still be cancelled, rescheduled or
  asked to move, whether its booker may move it at all, and whether a booking
  may bring guests.

  The verdict predicates read the system clock (`Tymeslot.Clock`) and log
  their blocked branches. The scheduling policy a booking time is checked
  against is `Tymeslot.Availability.Schedules.booking_config/2`. The attributes a booking is written with are assembled by
  `Tymeslot.Bookings.MeetingAttributes`, and its links by
  `Tymeslot.Bookings.MeetingLinks`.
  """
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.HostManaged
  alias Tymeslot.Meetings.MeetingState

  require Logger

  @typedoc "A meeting record with the fields required by the policy checks."
  @type meeting_record :: %{
          required(:status) => MeetingState.status(),
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
          :cancelled
          | :completed
          | :expired
          | :request_lapsed
          | :awaiting_approval
          | :awaiting_verification
          | :started
          | :past
          | :planned
          | :already_requested
          | :held_for_series_payment
          | :held_for_series_approval
  @type cancel_refusal :: :already_cancelled | {:not_cancellable, meeting_state()}
  @type reschedule_refusal :: {:not_reschedulable, meeting_state()}
  @type booker_move_refusal :: :managed_by_host

  @doc """
  Determines if a meeting can be cancelled.
  Checks both status and time constraints.
  """
  @spec can_cancel_meeting?(meeting_record()) :: :ok | {:error, cancel_refusal()}
  def can_cancel_meeting?(meeting) do
    cond do
      meeting.status == :cancelled ->
        {:error, :already_cancelled}

      meeting.status == :completed ->
        {:error, {:not_cancellable, :completed}}

      # See `slot_elapsing?/2`: an unanswered reschedule request stays open
      # only until its deadline, and is refused from then on even before the
      # expiry job has ended the meeting.
      MeetingState.reschedule_request_lapsed?(meeting) ->
        {:error, {:not_cancellable, :request_lapsed}}

      # An expired meeting (a lapsed approval request or an abandoned paid
      # checkout) has already been released: its slot was freed, the attendee
      # was told the request lapsed, and `Meetings.Approval` has already
      # refunded whatever was paid for it. Cancelling would overwrite that
      # outcome with `:cancelled` and run the whole cancellation pipeline
      # over it — a second pair of emails contradicting the expiry notice, a
      # `meeting.cancelled` webhook for a meeting that never happened, and a
      # calendar delete for an event already removed. The request-received
      # email's withdraw link stays live in the invitee's inbox after the
      # deadline, so this is a reachable click, not a theoretical one.
      meeting.status == :expired ->
        {:error, {:not_cancellable, :expired}}

      # Cancelling would run the cancellation pipeline, which emails and
      # notifies the organiser about a booking they must never hear of;
      # letting the hold lapse releases it silently.
      meeting.status == :awaiting_verification ->
        {:error, {:not_cancellable, :awaiting_verification}}

      # A session of a paid series still awaiting payment is held with its
      # whole series on one checkout. Cancelling it alone would leave the
      # payment unable to confirm the rest, so a held series is released only
      # whole, when its checkout expires or is abandoned.
      held_for_series_payment?(meeting) ->
        {:error, {:not_cancellable, :held_for_series_payment}}

      slot_elapsing?(meeting, &meeting_is_current?/1) ->
        Logger.info("Blocked cancellation: meeting has already started",
          meeting_id: Map.get(meeting, :id)
        )

        {:error, {:not_cancellable, :started}}

      slot_elapsing?(meeting, &meeting_is_past?/1) ->
        Logger.info("Blocked cancellation: meeting has already occurred",
          meeting_id: Map.get(meeting, :id)
        )

        {:error, {:not_cancellable, :past}}

      true ->
        :ok
    end
  end

  # A reschedule request has voided the slot, so its original time no longer
  # says when the meeting happens: the attendee may still answer the request,
  # and the host withdraw it, after that time has gone by, until the request's
  # own deadline (`MeetingState.reschedule_request_deadline/1`). A confirmed
  # meeting whose time has passed stays refused.
  defp slot_elapsing?(meeting, time_check),
    do: not MeetingState.awaiting_new_time?(meeting) and time_check.(meeting)

  defp held_for_series_payment?(%{status: :awaiting_payment, series_id: series_id})
       when is_binary(series_id),
       do: true

  defp held_for_series_payment?(_meeting), do: false

  # Only an open series request: a confirmed session the booker moved back
  # into the approval gate is a request of its own, moved like any single
  # booking awaiting approval.
  defp held_for_series_approval?(%{status: :awaiting_approval, series_id: series_id} = meeting)
       when is_binary(series_id),
       do: SeriesApproval.series_request?(meeting)

  defp held_for_series_approval?(_meeting), do: false

  @doc """
  Determines if a meeting can be rescheduled.
  Checks both status and time constraints.
  """
  @spec can_reschedule_meeting?(meeting_record()) :: :ok | {:error, reschedule_refusal()}
  def can_reschedule_meeting?(meeting) do
    cond do
      meeting.status == :cancelled ->
        {:error, {:not_reschedulable, :cancelled}}

      meeting.status == :completed ->
        {:error, {:not_reschedulable, :completed}}

      MeetingState.reschedule_request_lapsed?(meeting) ->
        {:error, {:not_reschedulable, :request_lapsed}}

      # As for cancelling, an expired meeting has already released its slot:
      # `MeetingState`'s `@occupying_statuses` excludes :expired, so conflict
      # detection ignores it. Rescheduling would move it to a new time it does
      # not reserve, and the attendee would be told about a booking anyone else
      # can still take.
      meeting.status == :expired ->
        {:error, {:not_reschedulable, :expired}}

      # As for cancelling: the organiser must never hear of a held booking,
      # and the host cannot see it to ask for a new time either.
      meeting.status == :awaiting_verification ->
        {:error, {:not_reschedulable, :awaiting_verification}}

      # A session of a series held for approval is one part of a request the
      # host answers whole (`Tymeslot.BookingSeries.Approval`). Moving it
      # alone would leave that request asking for a time the booker no
      # longer wants, so it stays put until the host has answered.
      held_for_series_approval?(meeting) ->
        {:error, {:not_reschedulable, :held_for_series_approval}}

      slot_elapsing?(meeting, &meeting_is_current?/1) ->
        Logger.info("Blocked reschedule: meeting has already started",
          meeting_id: Map.get(meeting, :id)
        )

        {:error, {:not_reschedulable, :started}}

      slot_elapsing?(meeting, &meeting_is_past?/1) ->
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

  A meeting already awaiting a new time from an earlier request is refused
  with `{:not_reschedulable, :already_requested}`: the attendee has been
  asked, and asking again would void the slot and email them a second time.

  A meeting confirmed from a poll (`Tymeslot.Meetings.HostManaged.managed?/1`) has
  nobody to ask for a new time: its host picks one with
  `Tymeslot.Bookings.HostMove.move/3`, so a request is refused with
  `:managed_by_host`.
  """
  @spec can_request_reschedule?(meeting_record()) ::
          :ok | {:error, reschedule_refusal() | booker_move_refusal()}
  def can_request_reschedule?(%{status: :awaiting_approval} = meeting) do
    with :ok <- can_booker_move_meeting?(meeting) do
      {:error, {:not_reschedulable, :awaiting_approval}}
    end
  end

  # A fixed date moves from its meeting type, keeping everyone booked on it.
  def can_request_reschedule?(%{planned: true}), do: {:error, {:not_reschedulable, :planned}}

  def can_request_reschedule?(meeting) do
    with :ok <- can_booker_move_meeting?(meeting),
         :ok <- can_reschedule_meeting?(meeting) do
      refuse_pending_request(meeting)
    end
  end

  # A request already voided the slot and is waiting on the attendee; a
  # second one would re-run the voiding and queue a duplicate email.
  defp refuse_pending_request(meeting) do
    if MeetingState.awaiting_new_time?(meeting),
      do: {:error, {:not_reschedulable, :already_requested}},
      else: :ok
  end

  @doc """
  Whether the host may change `meeting`'s time from the dashboard: by moving
  it themselves when they manage it (`can_reschedule_meeting?/1`), otherwise
  by asking its attendee for a new time (`can_request_reschedule?/1`).
  """
  @spec can_host_change_time?(meeting_record()) ::
          :ok | {:error, reschedule_refusal() | booker_move_refusal()}
  def can_host_change_time?(meeting) do
    if HostManaged.managed?(meeting),
      do: can_reschedule_meeting?(meeting),
      else: can_request_reschedule?(meeting)
  end

  @doc """
  Whether the booker may move `meeting` themselves. A meeting confirmed from
  a poll (`Tymeslot.Meetings.HostManaged.managed?/1`) has no booker: only its host
  moves it (`Tymeslot.Bookings.HostMove`). The flag never changes, so the
  answer needs no repeating under the meeting's lock.
  """
  @spec can_booker_move_meeting?(map()) :: :ok | {:error, booker_move_refusal()}
  def can_booker_move_meeting?(meeting) do
    if HostManaged.managed?(meeting), do: {:error, :managed_by_host}, else: :ok
  end

  @doc """
  Checks if a meeting is currently happening, comparing its times with the
  current UTC time.
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
