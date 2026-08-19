defmodule Tymeslot.Meetings.ApprovalJobs do
  @moduledoc """
  The background jobs a held booking request owns, and their removal.

  A request raised at 09:00 with a 24-hour window leaves two jobs sitting in
  the queue: a nudge at 21:00 and an expiry at 09:00 the next day. Both are
  wrong the instant the host answers, and both would be visible to the people
  involved — a reminder to decide something already decided, and an expiry
  that releases a slot the host accepted.

  So every exit from the gate calls `cancel/1`, and it is deliberately one
  call rather than two: a future exit path that remembers to cancel the nudge
  and forgets the expiry is exactly the bug this shape prevents.

  Cancellation is best-effort by design. Deleting a job that has already
  started executing is impossible, which is why neither job trusts the
  deletion: both re-read the meeting and check it is still held before acting,
  and `Approval`'s guarded transition refuses them if it is not.
  """

  require Logger

  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker

  @doc """
  Schedules the job that releases this request when its deadline passes.

  A request with no deadline recorded gets no expiry job; it is then held
  until a host answers, which is the honest reading of "no deadline". A
  deadline already in the past schedules for now rather than in the past, so
  Oban runs it on the next tick instead of treating it as overdue.
  """
  @spec schedule_expiry(%{atom() => term()}) :: :ok
  def schedule_expiry(%{approval_deadline_at: nil}), do: :ok

  def schedule_expiry(meeting) do
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
  Removes every pending job for a request that is no longer held.
  """
  @spec cancel(%{atom() => term()}) :: :ok
  def cancel(meeting) do
    {deleted, _returning} = ObanJobQueries.delete_meeting_jobs(ApprovalExpiryWorker, meeting.id)

    if deleted > 0 do
      Logger.info("Cancelled approval expiry", meeting_id: meeting.id, jobs_deleted: deleted)
    end

    :ok
  end
end
