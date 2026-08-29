defmodule Tymeslot.Meetings.Workers.ApprovalExpiryWorker do
  @moduledoc """
  Releases one held booking whose deadline has passed.

  Scheduled at `approval_deadline_at` when the request is raised, so the
  common case is punctual: the slot frees at the moment the window closes,
  not up to a sweep interval later.

  ## Why this is not the only expiry path

  A per-meeting scheduled job is a promise Oban cannot fully keep across a
  long wait. A window may be days wide, and in that time the job can be lost
  to a pruner misconfiguration, a failed insert nobody noticed, or a database
  restored from a backup taken before it was enqueued. Each of those leaves an
  invitee waiting on a request that will never resolve and a host's calendar
  holding a slot nobody can book.

  `ApprovalSweepWorker` is the backstop, and the two are safe to overlap:
  `Approval.expire/1` is a guarded transition, so whichever arrives second is
  told the request is no longer held and does nothing.

  Deliberately `max_attempts: 1`. A retry would fire minutes later against a
  request that is either already expired (nothing to do) or was answered in
  the interval (must not be touched), and the sweep covers the case where the
  single attempt genuinely failed.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: 315_360_000, fields: [:args, :worker], keys: [:meeting_id]]

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingState

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"meeting_id" => meeting_id}}) do
    case MeetingQueries.get_meeting(meeting_id) do
      {:ok, meeting} -> expire_if_held(meeting)
      {:error, :not_found} -> {:discard, "Meeting #{meeting_id} not found"}
    end
  end

  defp expire_if_held(meeting) do
    cond do
      not MeetingState.awaiting_approval?(meeting) ->
        # The host answered before the deadline, and the cancellation of this
        # job lost the race with its own execution. Nothing is wrong.
        {:discard, "Request already #{meeting.status}"}

      deadline_in_future?(meeting) ->
        # `ApprovalJobs.schedule_expiry/1` deletes a meeting's existing expiry
        # job before inserting a fresh one, but a delete that is itself lost
        # (the same class of failure `ApprovalSweepWorker`'s module docs
        # describe) can leave a stale job carrying an old, earlier deadline
        # behind a request that was re-armed with a later one. Comparing the
        # deadline here, not just the status, is what stops that stale job
        # from releasing a request that is still legitimately live.
        {:discard, "Request not due until #{meeting.approval_deadline_at}"}

      true ->
        release(meeting)
    end
  end

  defp deadline_in_future?(%{approval_deadline_at: nil}), do: false

  defp deadline_in_future?(%{approval_deadline_at: deadline}),
    do: DateTime.compare(deadline, Clock.utc_now()) == :gt

  defp release(meeting) do
    case Approval.expire(meeting) do
      {:ok, expired} ->
        Logger.info("Booking request expired at its deadline",
          meeting_id: expired.id,
          uid: expired.uid
        )

        :ok

      {:error, :not_awaiting_approval} ->
        {:discard, "Request answered while expiring"}
    end
  end
end
