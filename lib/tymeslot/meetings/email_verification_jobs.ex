defmodule Tymeslot.Meetings.EmailVerificationJobs do
  @moduledoc """
  The per-meeting job that releases an unverified booking at its deadline,
  and its removal.

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

  A failed insert is logged and otherwise ignored:
  `EmailVerificationSweepWorker` releases the booking within minutes, so the
  failure costs punctuality, not correctness.
  """
  @spec schedule_expiry(%{atom() => term()}) :: :ok
  def schedule_expiry(%{verification_deadline_at: %DateTime{} = deadline} = meeting) do
    inserted =
      %{"meeting_id" => meeting.id}
      |> EmailVerificationExpiryWorker.new(scheduled_at: deadline)
      |> Oban.insert()

    case inserted do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule email verification expiry",
          meeting_id: meeting.id,
          reason: LogFormat.reason(reason)
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
end
