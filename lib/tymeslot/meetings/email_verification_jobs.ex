defmodule Tymeslot.Meetings.EmailVerificationJobs do
  @moduledoc """
  The job that releases an unverified booking, or an unverified seat on a
  group meeting, at its deadline, and its removal.

  Cancellation is best-effort: a job already executing cannot be deleted. The
  job does not rely on it, since it re-reads the meeting and checks it is
  still held before acting, and `EmailVerification.expire/1` is a guarded
  transition that refuses a booking verified in the meantime.
  """

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Jobs
  alias Tymeslot.Meetings.Workers.EmailVerificationExpiryWorker

  @doc """
  Schedules the release of this booking at its `verification_deadline_at`.

  A failed insert is logged and otherwise ignored, and fails safe either way.
  Inside a transaction, a database-level insert error aborts that
  transaction, so the booking being created rolls back with it (as
  `:booking_failed`) rather than committing without its job. Outside one,
  `EmailVerificationSweepWorker` releases the booking within minutes of its
  deadline, so the failure costs punctuality, not correctness. A booking with
  no deadline is not gated and gets no job.
  """
  @spec schedule_expiry(%{atom() => term()}) :: :ok
  def schedule_expiry(%{verification_deadline_at: nil}), do: :ok

  def schedule_expiry(%{verification_deadline_at: %DateTime{} = deadline} = meeting),
    do: insert(%{"meeting_id" => meeting.id}, deadline, meeting_id: meeting.id)

  @doc """
  Schedules the release of this held group seat at its
  `verification_deadline_at`, as `schedule_expiry/1` does for a booking and
  failing safe the same way.
  """
  @spec schedule_seat_expiry(%{atom() => term()}) :: :ok
  def schedule_seat_expiry(%{verification_deadline_at: nil}), do: :ok

  def schedule_seat_expiry(%{verification_deadline_at: %DateTime{} = deadline} = seat),
    do: insert(%{"participant_id" => seat.id}, deadline, participant_id: seat.id)

  defp insert(args, deadline, log_metadata) do
    case args |> EmailVerificationExpiryWorker.new(scheduled_at: deadline) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Failed to schedule email verification expiry",
          [reason: LogFormat.reason(reason)] ++ log_metadata
        )
    end

    :ok
  end

  @doc "Removes the pending expiry job of a booking that is no longer held."
  @spec cancel(%{atom() => term()}) :: :ok
  def cancel(meeting) do
    Jobs.delete_meeting_jobs(EmailVerificationExpiryWorker, meeting.id)
    :ok
  end

  @doc "Removes the pending expiry job of a group seat that is no longer held."
  @spec cancel_seat(%{atom() => term()}) :: :ok
  def cancel_seat(seat) do
    Jobs.delete_participant_jobs(EmailVerificationExpiryWorker, seat.id)
    :ok
  end
end
