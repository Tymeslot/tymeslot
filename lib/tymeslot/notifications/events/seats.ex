defmodule Tymeslot.Notifications.Events.Seats do
  @moduledoc """
  The notification events of a seat on a group meeting: booked, cancelled
  and moved, the release of seat confirmations once a video room exists, and
  the seat's own integration dispatch. `Tymeslot.Notifications.Events`
  handles the meeting-level events and runs the deferred fan-outs these
  return.
  """

  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatView
  alias Tymeslot.Notifications.ChannelFanout
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Events.Guard
  alias Tymeslot.Notifications.Orchestrator

  @doc """
  Handles a seat being booked on a group meeting.

  Every seat schedules its own confirmation email job (participant plus a
  per-seat organiser notification). Reminders are meeting-level and scheduled
  exactly once, by `Tymeslot.Bookings.SeatEffects` at whichever seat's
  booking created the meeting — not here, so this never needs to know
  `created_meeting?`.

  The integration dispatchers fire per seat, not per slot, because a booking
  is a person: a host's webhook, Telegram or Slack automation needs to hear
  about the fifth booker as much as the first. Each carries that seat's
  participant (see `Tymeslot.Meetings.SeatView`), since the shared meeting
  row has no attendee of its own.

  The seat is booked inside a transaction, so, as with
  `Events.meeting_created_deferred/2`, the emails are scheduled now and the
  integration fan-out is returned as `pending`, for the caller to hand to
  `Events.dispatch_deferred/1` once the seat has committed.

  Options:
    * `:defer_emails?` — the caller has scheduled video-room creation and the
      room worker will release this seat's confirmation once the join link
      exists, so scheduling it here would only send a linkless duplicate.
    * `:emails` — `false` sends no confirmation for the seat, to the booker
      or the host: a seat of a booking series, whose booker and host are
      told about the whole series in one email instead.
    * `:integrations` — `false` returns no fan-out, as for
      `Events.meeting_created_deferred/2`.
  """
  @spec seat_booked_deferred(term(), term(), keyword()) ::
          {{:ok, term()} | {:error, term()}, Events.pending()}
  def seat_booked_deferred(meeting, participant, opts \\ []) do
    result =
      cond do
        not Keyword.get(opts, :emails, true) ->
          {:ok, :confirmed_with_series}

        Keyword.get(opts, :defer_emails?, false) ->
          {:ok, :deferred_to_video_room}

        true ->
          # As for a solo booking: only a storage failure rolls the seat back;
          # a fault composing its emails would refuse the seat on every retry.
          :seat_booked
          |> Guard.send_notifications(meeting, fn ->
            Orchestrator.schedule_seat_confirmation(meeting, participant)
          end)
          |> Guard.retryable_only(:seat_booked, meeting)
      end

    if integrations?(opts),
      do: {result, [{:meeting_created, meeting, {:seat, participant}}]},
      else: {result, []}
  end

  # A room job that finishes after the host cancelled the meeting has no
  # confirmations left to release: the participants were told it is off.
  @doc """
  Releases the confirmation email of every live seat of a group meeting
  whose video room job has run (`Events.announce_video_room_outcome/1`).
  """
  @spec release_confirmations(term()) :: :ok
  def release_confirmations(%{status: :cancelled}), do: :ok

  # A series' seat is confirmed by its series (`seat_booked_deferred/3`'s
  # `emails: false`), even on a session whose first booker's room job is
  # still holding the other seats' confirmations when the series joins it.
  def release_confirmations(meeting) do
    meeting.id
    |> ParticipantQueries.list_live_for_meeting()
    |> Enum.filter(&is_nil(&1.series_id))
    |> Enum.each(&Orchestrator.schedule_seat_confirmation(meeting, &1))
  end

  @doc """
  Handles a participant cancelling their seat on a group meeting.

  Schedules the seat-cancellation emails. `slot_freed: true` marks the last
  leaver: their leaving cancelled the meeting, and the organiser's email
  about the seat says so (it is the organiser's only email about it).

  Integrations hear `meeting.cancelled` for this seat. For the last leaver
  that is the only one: the meeting-level cancellation that follows finds no
  live seat left to announce, and an empty slot was never a booking.

  `emails: false` schedules no email: the seat was given up with the rest of
  its series, which tells both sides once (`Tymeslot.BookingSeries.Cancel`).
  `integrations: false` tells no integration, as for `Events.meeting_cancelled/2`.
  """
  @spec seat_cancelled(term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def seat_cancelled(meeting, participant, opts \\ []) do
    result =
      if Keyword.get(opts, :emails, true) do
        Orchestrator.schedule_seat_cancellation(
          meeting,
          participant,
          Keyword.get(opts, :slot_freed, false)
        )
      else
        {:ok, :announced_with_series}
      end

    if integrations?(opts), do: dispatch(:meeting_cancelled, meeting, participant)

    result
  end

  @doc """
  Handles a participant's seat moving to a new slot (move-my-seat).

  Schedules the reschedule email: a confirmation for the new seat whose
  attachments also cancel the old seat's calendar entry for the participant,
  and the matching cancellation and invitation for their guests.
  `old_participant` is the seat row the move cancelled on `old_meeting`;
  each seat is its own calendar entry, so the old one is named by that row,
  not by the old meeting. `old_slot_freed: true` says the move emptied, and
  so cancelled, the old meeting.

  Integrations hear `meeting.rescheduled` for the new seat, the way a solo
  booking's move is one rescheduled booking rather than a cancellation and a
  new one. A move gives the seat a new participant row, and usually a new
  meeting, so the event names the seat it replaced (`SeatView.previous/2`)
  for a consumer to link the two.
  """
  @spec seat_rescheduled(term(), term(), term(), term(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def seat_rescheduled(meeting, participant, old_meeting, old_participant, opts \\ []) do
    result =
      Orchestrator.schedule_seat_reschedule(
        meeting,
        participant,
        old_participant,
        Keyword.get(opts, :old_slot_freed, false)
      )

    dispatch(
      :meeting_rescheduled,
      meeting,
      participant,
      SeatView.previous(old_meeting, old_participant)
    )

    result
  end

  @doc """
  Tells the integrations `event` about `participant`'s seat on `meeting`,
  as that seat's booking (`Tymeslot.Meetings.SeatView`); `previous` is the
  seat a move replaced.
  """
  @spec dispatch(atom(), term(), term(), SeatView.previous() | nil) :: term()
  def dispatch(event, meeting, participant, previous \\ nil) do
    Guard.seat_guard(event, meeting, fn ->
      ChannelFanout.dispatch(event, SeatView.at_event(meeting, participant, nil, previous))
    end)
  end

  defp integrations?(opts), do: Keyword.get(opts, :integrations, true)
end
