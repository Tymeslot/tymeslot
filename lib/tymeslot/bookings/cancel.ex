defmodule Tymeslot.Bookings.Cancel do
  @moduledoc """
  Orchestrates the booking cancellation process.
  Handles meeting status updates, calendar event deletion, and notifications.
  """

  require Logger

  alias Tymeslot.Availability
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.BookingSeries
  alias Tymeslot.BookingSeries.Approval, as: SeriesApproval
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.HostManaged
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  @external_cancellation_reason "Cancelled externally via calendar sync"

  @doc """
  Cancels a meeting.

  This includes:
  1. Updating meeting status in database
  2. Cancelling calendar event
  3. Deleting pending reminder email jobs
  4. Sending cancellation emails
  5. Closing the meeting's series when nothing of it is left to come
     (`BookingSeries.maybe_close/1`)

  ## Options

    * `:announce` - `false` cancels without step 4, for a caller whose
      announcement depends on something it has yet to do (a refund the
      cancellation email reports on). That caller owes an `announce/1` once it
      has settled. Defaults to `true`.
    * `:close_series` - `false` leaves the meeting's series open (step 5),
      for a caller that cancels several sessions of it in one transaction
      and closes it once itself (`Tymeslot.BookingSeries.Cancel`). Defaults
      to `true`.
  Returns {:ok, meeting} or {:error, reason}. `{:error, :already_cancelled}`
  means the meeting was cancelled already, whether `meeting` says so or a
  concurrent request cancelled it after `meeting` was read; whoever cancelled
  it ran the side effects, so this call ran none.

  Accepts the same `opts` as `validate_cancellation/2`; see there for
  `:caller`.
  """
  @spec execute(Meeting.t(), keyword()) :: {:ok, Meeting.t()} | {:error, term()}
  def execute(%Meeting{} = meeting, opts \\ []) do
    case run(meeting, opts, nil) do
      {:ok, cancelled, nil} -> {:ok, cancelled}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Cancels a meeting as `execute/2` does, running `on_cancelled` in one
  transaction with step 1, once the meeting row is cancelled (and so
  locked): the work that must commit with the cancellation or not at all
  (`Tymeslot.Meetings.Cancellation` releasing seat holds and scheduling seat
  refunds). `on_cancelled` returns `{:ok, result}` or `{:error, reason}`;
  `{:error, reason}` rolls the cancellation back and is returned.

  Returns `{:ok, meeting, result}`, where `result` is the callback's, or
  `nil` for a held request, which is withdrawn without running it; or
  `{:error, reason}` as for `execute/2`. Takes the same `opts`.
  """
  @spec execute_settling(
          Meeting.t(),
          (Meeting.t() -> {:ok, term()} | {:error, term()}),
          keyword()
        ) ::
          {:ok, Meeting.t(), term()} | {:error, term()}
  def execute_settling(%Meeting{} = meeting, on_cancelled, opts \\ [])
      when is_function(on_cancelled, 1),
      do: run(meeting, opts, on_cancelled)

  defp run(%Meeting{status: :cancelled} = meeting, _opts, _on_cancelled) do
    Logger.info("Skipping cancellation for already-cancelled meeting",
      meeting_id: meeting.id
    )

    {:error, :already_cancelled}
  end

  defp run(meeting, opts, on_cancelled) do
    # Validation covers the Policy time checks plus the group-meeting guard.
    case validate_cancellation(meeting, opts) do
      :ok ->
        result = execute_permitted(meeting, opts, on_cancelled)
        if Keyword.get(opts, :close_series, true), do: close_series(result)
        result

      {:error, reason} ->
        policy_blocked(meeting, reason)
    end
  end

  # A series whose last session still to come was just cancelled is over:
  # it is closed with no email of its own, each session having had its own.
  defp close_series({:ok, %Meeting{series_id: series_id}}) when is_binary(series_id),
    do: BookingSeries.maybe_close(series_id)

  defp close_series({:ok, %Meeting{series_id: series_id}, _settled}) when is_binary(series_id),
    do: BookingSeries.maybe_close(series_id)

  defp close_series(_result), do: :ok

  @doc """
  Tells everyone a meeting was cancelled: the cancellation emails, the
  reminder clean-up, and the webhook, Telegram and Slack notifications. A
  failure is logged and never fails the cancellation.

  `execute/2` does this itself unless it was asked not to.
  """
  @spec announce(Meeting.t()) :: :ok
  def announce(%Meeting{} = meeting), do: send_cancellation_notifications(meeting)

  @doc """
  As `announce/1`, for a group session the host cancelled:
  `seat_refund:` (`Tymeslot.Meetings.Cancellation.seat_refund/0`) says
  whether its paid seats are being refunded, how many and how much, for
  the organiser's cancellation email. Participants are never told.
  """
  @spec announce(Meeting.t(), [{:seat_refund, Tymeslot.Meetings.Cancellation.seat_refund()}]) ::
          :ok
  def announce(%Meeting{} = meeting, opts),
    do: send_cancellation_notifications(meeting, Keyword.take(opts, [:seat_refund]))

  # A held request is not a confirmed booking being called off — it is the
  # invitee withdrawing before the host ever agreed to it. That transition
  # belongs to `Approval`, which guards it against the same race an approval,
  # a decline or the expiry sweep can win, and which owns the refund rule for
  # a request that never became a meeting. Only the notification stays here:
  # `Approval.withdraw/2` does not send one, since decline and expire each
  # need their own wording and withdrawal needs neither.
  # Both paths answer `{:ok, meeting, result}`, `result` being `nil` when
  # no callback ran.
  defp execute_permitted(meeting, opts, on_cancelled) do
    announce? = Keyword.get(opts, :announce, true)

    if MeetingState.awaiting_approval?(meeting) do
      with {:ok, released} <- withdraw_held_request(meeting, announce?),
           do: {:ok, released, nil}
    else
      cancel_confirmed_meeting(meeting, announce?, on_cancelled)
    end
  end

  defp maybe_announce(meeting, true), do: send_cancellation_notifications(meeting)
  defp maybe_announce(_meeting, false), do: :ok

  defp withdraw_held_request(meeting, announce?) do
    Logger.info("Withdrawing held booking request",
      meeting_id: meeting.id
    )

    announce? = announce? and announces_withdrawal?(meeting)

    with {:ok, released} <- withdraw(meeting, []),
         :ok <- maybe_announce(released, announce?) do
      {:ok, released}
    else
      {:error, :already_cancelled} = error ->
        error

      {:error, reason} = error ->
        Logger.error("Failed to withdraw booking request",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  defp cancel_confirmed_meeting(meeting, announce?, on_cancelled) do
    Logger.info("Cancelling meeting",
      meeting_id: meeting.id
    )

    with {:ok, updated_meeting, settled} <- cancel_row(meeting, nil, on_cancelled),
         :ok <- Meetings.cancel_calendar_event(updated_meeting),
         :ok <- delete_provider_video_room(updated_meeting),
         :ok <- maybe_announce(updated_meeting, announce?) do
      {:ok, updated_meeting, settled}
    end
  end

  # Without a callback the status flip commits on its own, as it always
  # has. With one, the flip and the callback commit together, and the
  # slot is offered again only once they have.
  defp cancel_row(meeting, cancellation_reason, nil) do
    with {:ok, updated_meeting} <- transition_to_cancelled(meeting, cancellation_reason) do
      Availability.changed(updated_meeting.organizer_user_id)
      {:ok, updated_meeting, nil}
    end
  end

  defp cancel_row(meeting, cancellation_reason, on_cancelled)
       when is_function(on_cancelled, 1) do
    result =
      Repo.transaction(fn ->
        with {:ok, updated_meeting} <- transition_to_cancelled(meeting, cancellation_reason),
             {:ok, settled} <- on_cancelled.(updated_meeting) do
          {updated_meeting, settled}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {updated_meeting, settled}} ->
        Availability.changed(updated_meeting.organizer_user_id)
        {:ok, updated_meeting, settled}

      {:error, _reason} = error ->
        error
    end
  end

  defp policy_blocked(meeting, reason) do
    Logger.warning("Meeting cancellation blocked by policy",
      meeting_id: meeting.id,
      reason: LogFormat.reason(reason)
    )

    {:error, reason}
  end

  @doc """
  Runs the side effects of a cancellation whose status flip has already been
  committed by the caller: calendar event deletion, provider video cleanup,
  and the cancellation notifications.

  `execute/1` flips the status itself, which is right for a host cancelling a
  whole meeting. It is wrong for the last participant leaving a group slot:
  there, the flip must happen inside the seat transaction, under the meeting
  row lock, or a concurrent booker can join the slot in the window between the
  seat committing and the meeting being cancelled. `Tymeslot.Bookings.CancelSeat`
  therefore commits the flip itself and calls this to finish the job.

  `emails: false` schedules no cancellation email job, for a meeting
  emptied by a series giving up its seats, which tells both sides itself
  (`Tymeslot.BookingSeries.Cancel`); `integrations: false` likewise tells
  no integration.
  """
  @spec finalise_cancellation(Meeting.t(), keyword()) :: :ok
  def finalise_cancellation(%Meeting{} = meeting, opts \\ []) do
    Availability.changed(meeting.organizer_user_id)

    with :ok <- Meetings.cancel_calendar_event(meeting),
         :ok <- delete_provider_video_room(meeting) do
      send_cancellation_notifications(meeting, opts)
    else
      {:error, reason} ->
        Logger.error("Failed to finalise cancellation of emptied group meeting",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  @doc """
  Cancels a meeting due to external calendar deletion.

  Bypasses policy checks (external deletions may arrive for past meetings)
  and skips calendar event deletion (the event is already gone). Only
  proceeds if the meeting still expects a provider event to exist (see
  `MeetingState.expects_calendar_event?/1`) — a void slot, such as a
  pending reschedule request, legitimately has no event, so its absence
  must not trigger an auto-cancel.

  Closes the meeting's series when nothing of it is left to come, as
  `execute/2` does.

  A group meeting's seat holds still open are released with it
  (`:meeting_cancelled`), and once that has committed their checkouts are
  expired and their bookers told, as when the host cancels from the
  dashboard. Its paid seats are not refunded, as a paid one-to-one
  meeting cancelled this way is not: deleting the event from a calendar
  says nothing about the money, which the host can refund from the
  payments page.

  Returns {:ok, meeting} or {:error, reason}, where `:already_cancelled`
  means the meeting was cancelled by some other path first, as for
  `execute/2`.
  """
  @spec execute_external(Meeting.t()) :: {:ok, Meeting.t()} | {:error, term()}
  def execute_external(%Meeting{} = meeting) do
    if MeetingState.expects_calendar_event?(meeting) do
      result = auto_cancel_external(meeting)
      close_series(result)
      result
    else
      Logger.info("Skipping auto-cancel for externally deleted meeting",
        meeting_id: meeting.id,
        status: meeting.status
      )

      {:ok, meeting}
    end
  end

  @doc """
  Validates if a meeting can be cancelled.
  Delegates to Policy module for consistent validation.

  `opts`:
    * `:caller` — pass `:organizer` for an authenticated organiser cancelling
      the whole meeting from their own dashboard. Any other value (including
      the default, no opts) is treated as the public, participant-facing
      surface and refuses a live group meeting — see `refuse_group_meeting/2`.

  Returns :ok or {:error, reason}
  """
  @spec validate_cancellation(Meeting.t(), keyword()) ::
          :ok
          | {:error, Policy.cancel_refusal() | :group_meeting_not_cancellable | :managed_by_host}
  def validate_cancellation(meeting, opts \\ []) do
    with :ok <- Policy.can_cancel_meeting?(meeting),
         :ok <- refuse_group_meeting(meeting, opts) do
      refuse_host_managed(meeting, opts)
    end
  end

  # Private functions

  # A group slot is shared, so flipping the meeting row to :cancelled here
  # would cancel every other participant's seat, not just whoever is asking.
  # The public, unauthenticated meeting-level surface
  # (`/:username/meeting/:uid/cancel`) never passes `caller: :organizer`, so
  # it is refused by default; an authenticated
  # organiser cancelling the whole meeting from their own dashboard is a
  # deliberate, distinct action and opts in explicitly.
  #
  # Participants cancel their own seat through `Tymeslot.Bookings.CancelSeat`,
  # which never reaches here. `Tymeslot.Bookings.SeatRelease` legitimately
  # cancels the meeting itself once its last seat is released, but it flips
  # the status directly under the meeting row lock and calls
  # `finalise_cancellation/1` to finish the job — it does not go through
  # `execute/1`, so it is unaffected by this guard regardless of `opts`.
  defp refuse_group_meeting(meeting, opts) do
    if Meetings.group?(meeting) and Keyword.get(opts, :caller) != :organizer do
      {:error, :group_meeting_not_cancellable}
    else
      :ok
    end
  end

  # A meeting confirmed from a poll has no booker who may cancel it for
  # everyone: only the host may, from their dashboard. Each invitee answers
  # for themselves with the RSVP links in their invitation.
  defp refuse_host_managed(meeting, opts) do
    if HostManaged.managed?(meeting) and Keyword.get(opts, :caller) != :organizer do
      {:error, :managed_by_host}
    else
      :ok
    end
  end

  # Same split as `execute_permitted/1`: the host deleting the tentative hold
  # from their own calendar is, for a held request, indistinguishable from
  # the invitee withdrawing it — nobody answered, the slot is simply free
  # again — so it goes through the same guarded `Approval.withdraw/2` rather
  # than the plain changeset write: the withdrawal disarms the nudge and the
  # expiry sweep and refunds a request that was paid for.
  defp auto_cancel_external(meeting) do
    if MeetingState.awaiting_approval?(meeting) do
      withdraw_held_request_external(meeting)
    else
      cancel_confirmed_meeting_external(meeting)
    end
  end

  defp withdraw_held_request_external(meeting) do
    Logger.info("Auto-withdrawing externally deleted booking request",
      meeting_id: meeting.id
    )

    announce? = announces_withdrawal?(meeting)

    with {:ok, released} <-
           withdraw(meeting,
             cancellation_reason: @external_cancellation_reason,
             withdrawn_by: :calendar
           ),
         :ok <- maybe_announce(released, announce?) do
      {:ok, released}
    else
      {:error, :already_cancelled} = error ->
        error

      {:error, reason} = error ->
        Logger.error("Failed to auto-withdraw externally deleted booking request",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  defp cancel_confirmed_meeting_external(meeting) do
    Logger.info("Auto-cancelling externally deleted meeting",
      meeting_id: meeting.id
    )

    with {:ok, updated_meeting, released} <-
           cancel_row(meeting, @external_cancellation_reason, release_seat_holds(meeting)),
         :ok <- Checkout.abandon_released_seat_holds(released || []),
         :ok <- delete_provider_video_room(updated_meeting),
         :ok <- send_cancellation_notifications(updated_meeting) do
      {:ok, updated_meeting}
    end
  end

  # A group meeting's open holds are released in the cancellation's own
  # transaction, after its row is cancelled and so locked: the lock order
  # every writer of a hold keeps.
  defp release_seat_holds(meeting) do
    if Meetings.group?(meeting),
      do: &{:ok, SeatHolds.release_open_for_meeting(&1.id, :meeting_cancelled)}
  end

  # A session of a series request is withdrawn with its whole series
  # (`Approval.withdraw/2`), which tells both sides once for all of it; an
  # email for this one session would contradict that. Asked before the
  # withdrawal, which ends the request. Every other withdrawal, and every
  # cancellation of a confirmed session, is announced as usual.
  defp announces_withdrawal?(meeting), do: not SeriesApproval.series_request?(meeting)

  # A withdrawal loses its race when the host declined the request or the
  # expiry sweep released it after `meeting` was read. That is the same
  # outcome as losing a cancellation race, so it is reported the same way and
  # the invitee is told the booking is already cancelled. A request the host
  # approved meanwhile is still live, and keeps `:not_awaiting_approval`.
  defp withdraw(meeting, extra_changes) do
    case Approval.withdraw(meeting, extra_changes) do
      {:error, :not_awaiting_approval} = error -> lost_withdrawal(meeting, error)
      result -> result
    end
  end

  defp lost_withdrawal(meeting, error) do
    case MeetingQueries.get_meeting(meeting.id) do
      {:ok, current} ->
        if MeetingState.terminal?(current) do
          Logger.info("Booking request was already released by a concurrent request",
            meeting_id: meeting.id,
            status: current.status
          )

          {:error, :already_cancelled}
        else
          error
        end

      {:error, :not_found} ->
        error
    end
  end

  # The status flip is guarded (see `MeetingTransitionQueries.transition_to_cancelled/2`):
  # `meeting` may be a copy read before a concurrent cancellation committed,
  # and only the caller whose write actually cancelled the row goes on to
  # delete the calendar event and tell everyone. The loser gets
  # `{:error, :already_cancelled}` and does nothing further. The caller
  # offers the slot again (`Availability.changed/1`) once the flip has
  # committed (`cancel_row/3`). Except on the series path: when
  # `Tymeslot.BookingSeries.Cancel` cancels several sessions inside one
  # transaction of its own, `cancel_row/3` runs within it, so
  # `Availability.changed/1` fires before that outer transaction commits.
  #
  # A group slot's seats still awaiting email verification go with it, in the
  # same transaction and after the slot row (the lock order every seat
  # transition keeps), silently: nobody but each held booker knew of them,
  # and a seat left live on a cancelled slot could later be confirmed into it.
  defp transition_to_cancelled(meeting, cancellation_reason) do
    changes =
      Enum.reject(
        [
          cancelled_at: DateTime.truncate(Clock.utc_now(), :second),
          cancellation_reason: cancellation_reason
        ],
        fn {_key, value} -> is_nil(value) end
      )

    case cancel_with_held_seats(meeting, changes) do
      {:ok, updated_meeting} ->
        Logger.info("Meeting status updated to cancelled",
          meeting_id: meeting.id,
          cancellation_reason: cancellation_reason
        )

        {:ok, updated_meeting}

      {:error, :already_cancelled} = error ->
        Logger.info("Meeting was already cancelled by a concurrent request",
          meeting_id: meeting.id
        )

        error

      {:error, reason} = error ->
        Logger.error("Failed to cancel meeting",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end

  # A booking cancelled while its checkout is open has the checkout closed
  # by a job committed with the cancellation, so its attendee cannot pay for
  # it afterwards, and Stripe is not called under these locks. A payment
  # that completes before the close is refunded in full when it does
  # (`Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted`).
  defp cancel_with_held_seats(meeting, changes) do
    Repo.transaction(fn ->
      with {:ok, cancelled} <-
             MeetingTransitionQueries.transition_to_cancelled(meeting.id, changes),
           :ok <- EmailVerification.release_all_held(cancelled.id),
           :ok <- Checkout.schedule_checkout_close(meeting) do
        cancelled
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Enqueues the video-sync job that deletes the provider-side meeting (e.g.
  # Zoom) so it does not linger in the organiser's account. Whether an
  # integration can still reach the room is decided inside the job, not here:
  # a severed `video_integration_id` does not mean the room stopped existing.
  # Never blocks cancellation. See `Reschedule` for why this goes through Oban.
  defp delete_provider_video_room(%Meeting{video_room_id: nil}), do: :ok
  defp delete_provider_video_room(%Meeting{organizer_user_id: nil}), do: :ok

  defp delete_provider_video_room(%Meeting{} = meeting) do
    case VideoSyncWorker.enqueue(meeting.id, "delete") do
      {:ok, _status} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue provider video deletion on cancellation",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end

  # The cancellation email carries a `STATUS:CANCELLED` ICS attachment (see
  # `Tymeslot.Emails.Templates.AppointmentCancellation`) so the attendee's
  # calendar client marks the event as cancelled. It is deliberately not
  # routed through `Tymeslot.Meetings.AttendeeNotifications.event_deleted_confirm/2`:
  # that calendar-update template cannot carry the cancellation reason or
  # custom copy, and double-routing would send two cancellation emails.
  defp send_cancellation_notifications(meeting, opts \\ []) do
    case Events.meeting_cancelled(meeting, opts) do
      {:ok, _result} ->
        Logger.info("Cancellation emails sent", meeting_id: meeting.id)
        :ok

      {:error, reason} ->
        # A cancellation that notifies nobody is a real defect, not a
        # routine hiccup, so this is logged loudly. It still does not fail
        # the cancellation itself: the meeting is already cancelled and
        # blocking that on email delivery would strand the caller.
        Logger.error("Failed to send cancellation notifications",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
        )

        :ok
    end
  end
end
