defmodule Tymeslot.Meetings.EmailVerification.Resend do
  # Resends after the email sent with the booking or seat.
  @max_resends 3

  @moduledoc """
  Sends a held booking's or a held seat's verification email again; reached
  through `Tymeslot.Meetings.EmailVerification.resend/1` and `resend_seat/1`.

  Both holds follow the same rules, so they share one path: the email goes
  out again with the same link deadline, never extending the hold, while the
  hold is live and its deadline ahead, at most #{@max_resends} times after the email sent
  with the booking. The count and the email job commit together, so a resend
  that could not be queued (`:not_scheduled`) costs the booker nothing. A
  resend at or after the deadline releases the hold, as its expiry would.
  A seat whose slot a pending reschedule request has voided is refused
  (`:slot_void`) before anything is counted: the email would never go out
  (its job is discarded on a slot whose time does not hold) and its link
  could not confirm the seat meanwhile, so the booker keeps the resend.
  What differs between a booking and a seat (where the count lives, which
  email is scheduled, how the hold is released) is dispatched on the struct.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.MeetingTransitionQueries
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.ParticipantSchema, as: Participant
  alias Tymeslot.Repo

  @type hold :: Meeting.t() | Participant.t()

  @doc """
  Sends the hold's verification email again. See the moduledoc for the rules
  and `t:Tymeslot.Meetings.EmailVerification.resend_error/0` for the refusals.
  """
  @spec resend(hold()) :: {:ok, hold()} | {:error, EmailVerification.resend_error()}
  def resend(hold) do
    now = Clock.utc_now()

    counted =
      Repo.transaction(fn ->
        with :ok <- ensure_time_holds(hold, now),
             {:ok, counted} <- count(hold, now),
             :ok <- schedule(counted) do
          counted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    outcome(counted, hold, now)
  end

  @doc """
  How many more times the hold's verification email may be resent, by its
  stored count alone. A count never written reads as the email sent with the
  booking.
  """
  @spec resends_left(hold()) :: non_neg_integer()
  def resends_left(%{verification_emails_sent: sent}) when is_integer(sent),
    do: max(@max_resends + 1 - sent, 0)

  def resends_left(%{verification_emails_sent: nil}), do: @max_resends

  # Read under the slot's row lock, so a reschedule request written
  # meanwhile is either seen here or waits for the count to commit. A seat
  # that is no longer held, or a slot gone altogether, is left for the count
  # to refuse.
  defp ensure_time_holds(%Participant{} = seat, now) do
    case MeetingQueries.get_meeting_for_update(seat.meeting_id) do
      {:ok, slot} ->
        if EmailVerification.seat_standing(slot, seat, now) == :slot_void,
          do: {:error, :slot_void},
          else: :ok

      {:error, :not_found} ->
        :ok
    end
  end

  defp ensure_time_holds(%Meeting{}, _now), do: :ok

  defp count(%Meeting{id: id}, now),
    do: MeetingTransitionQueries.count_verification_email(id, now, @max_resends + 1)

  defp count(%Participant{id: id}, now),
    do: ParticipantQueries.count_verification_email(id, now, @max_resends + 1)

  defp schedule(%Meeting{} = counted),
    do: EmailScheduler.schedule_verification_email(counted.id, counted.verification_emails_sent)

  defp schedule(%Participant{} = counted) do
    EmailScheduler.schedule_seat_verification_email(
      counted.meeting_id,
      counted.id,
      counted.verification_emails_sent
    )
  end

  defp outcome({:ok, counted}, _hold, _now) do
    Logger.info(
      "Verification email resent",
      log_ids(counted) ++ [send: counted.verification_emails_sent]
    )

    {:ok, counted}
  end

  defp outcome({:error, :refused}, hold, now) do
    case reload(hold) do
      {:ok, current} -> refusal(current, now)
      {:error, :not_found} -> {:error, :not_awaiting_verification}
    end
  end

  defp outcome({:error, :slot_void}, hold, _now) do
    Logger.info("Verification email not resent: the slot awaits a new time", log_ids(hold))
    {:error, :slot_void}
  end

  defp outcome({:error, reason}, hold, _now) do
    Logger.error(
      "Verification email could not be resent",
      log_ids(hold) ++ [reason: LogFormat.reason(reason)]
    )

    {:error, :not_scheduled}
  end

  defp refusal(hold, now) do
    cond do
      not held?(hold) -> {:error, :not_awaiting_verification}
      EmailVerification.deadline_reached?(hold, now) -> expire(hold)
      true -> {:error, :limit_reached}
    end
  end

  # A verification may have won in between, so a refused release reads as
  # nothing left to resend.
  defp expire(hold) do
    case release(hold) do
      {:ok, _expired} -> {:error, :expired}
      {:error, :not_awaiting_verification} = refused -> refused
    end
  end

  defp reload(%Meeting{id: id}), do: MeetingQueries.get_meeting(id)
  defp reload(%Participant{id: id}), do: ParticipantQueries.get(id)

  defp held?(%Meeting{} = meeting), do: MeetingState.awaiting_verification?(meeting)

  defp held?(%Participant{} = seat),
    do: Participant.live?(seat) and Participant.unverified?(seat)

  defp release(%Meeting{} = meeting), do: EmailVerification.expire(meeting)
  defp release(%Participant{} = seat), do: EmailVerification.expire_seat(seat)

  defp log_ids(%Meeting{id: id}), do: [meeting_id: id]
  defp log_ids(%Participant{} = seat), do: [meeting_id: seat.meeting_id, participant_id: seat.id]
end
