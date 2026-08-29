defmodule Tymeslot.Meetings.ApprovalJobs do
  @moduledoc """
  The background job a held booking request's expiry owns, and its removal.

  This module owns one job: the per-meeting expiry scheduled at
  `approval_deadline_at`. The nudge is a separate job owned by
  `Tymeslot.Emails.EmailScheduler.MeetingScheduler`; the two are cancelled
  together, but by `Tymeslot.Notifications.Orchestrator.cancel_request_notifications/1`,
  not by this module — `cancel/1` here removes only the expiry.

  Cancellation is best-effort by design. Deleting a job that has already
  started executing is impossible, which is why the job does not trust the
  deletion: it re-reads the meeting and checks it is still held before
  acting, and `Approval`'s guarded transition refuses it if it is not.
  """

  require Logger

  alias Tymeslot.Jobs
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker

  @doc """
  Schedules the job that releases this request when its deadline passes.

  A request with no deadline recorded gets no expiry job; it is then held
  until a host answers, which is the honest reading of "no deadline". A
  deadline already in the past schedules for now rather than in the past, so
  Oban runs it on the next tick instead of treating it as overdue.

  Deletes any expiry already scheduled for this meeting first. A request that
  re-enters the gate (e.g. an invitee reschedules a held request, which
  raises a new deadline for it) must not lose its insert to Oban's own
  uniqueness constraint on the *old* job: `unique` on `ApprovalExpiryWorker`
  keys on `meeting_id` alone, so without this the old deadline would win
  silently and release the slot early.
  """
  @spec schedule_expiry(%{atom() => term()}) :: :ok
  def schedule_expiry(%{approval_deadline_at: nil}), do: :ok

  def schedule_expiry(meeting) do
    delete_expiry_jobs(meeting)

    inserted =
      %{"meeting_id" => meeting.id}
      |> ApprovalExpiryWorker.new(scheduled_at: meeting.approval_deadline_at)
      |> Oban.insert()

    case inserted do
      {:ok, _job} ->
        Logger.info("Approval expiry scheduled",
          meeting_id: meeting.id,
          approval_deadline_at: meeting.approval_deadline_at
        )

      {:error, reason} ->
        # The sweep will still catch this request, so a failed insert degrades
        # punctuality rather than correctness.
        Logger.error("Failed to schedule approval expiry",
          meeting_id: meeting.id,
          reason: inspect(reason)
        )
    end

    :ok
  end

  @doc """
  Removes the pending expiry job for a request that is no longer held.
  """
  @spec cancel(%{atom() => term()}) :: :ok
  def cancel(meeting) do
    {deleted, _returning} = delete_expiry_jobs(meeting)

    if deleted > 0 do
      Logger.info("Cancelled approval expiry", meeting_id: meeting.id, jobs_deleted: deleted)
    end

    :ok
  end

  defp delete_expiry_jobs(meeting), do: Jobs.delete_meeting_jobs(ApprovalExpiryWorker, meeting.id)
end
