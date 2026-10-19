defmodule Tymeslot.Workers.AccountDeletionWorker do
  @moduledoc """
  Deletes one account once its deletion is due; the work itself is
  `Tymeslot.Auth.AccountDeletion.Runner`. Queued for `deletion_scheduled_at`
  when a deletion is requested, and again by the daily sweep for an overdue
  account whose job was lost or discarded.

  Unique per user while a job is waiting or running, so a double submit or a
  sweep never queues a second one; a restore deletes the waiting job. A
  refusal from the deletion hook (billing unreachable, say) is retried with
  Oban's backoff, and once the attempts run out the sweep tries again the
  next day. The last attempt of each run raises an
  `:account_deletion_stalled` admin alert, as a refusal that persists would
  otherwise repeat daily with nothing but a log line; the alert is deduplicated
  per account for 24 hours. A deletion re-requested while the old job is still executing
  conflicts with it, and gets its job from the next sweep.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:user_id], states: :incomplete]

  alias Tymeslot.Auth
  alias Tymeslot.Infrastructure.AdminAlerts

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args} = job) when is_integer(user_id) do
    case Auth.run_scheduled_deletion(user_id, force: Map.get(args, "force") == true) do
      {:ok, _outcome} ->
        :ok

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, reason} ->
        if job.attempt >= job.max_attempts, do: alert(user_id, reason)
        {:error, reason}
    end
  end

  @doc """
  Queues the deletion of `user_id` for `at`. `force: true` carries a
  release-shell deletion forced past the last-admin rule into the job, so a
  forced deletion that falls back to the job is not held.
  """
  @spec schedule(pos_integer(), DateTime.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def schedule(user_id, %DateTime{} = at, opts \\ []) do
    %{"user_id" => user_id}
    |> put_force(Keyword.get(opts, :force, false))
    |> new(scheduled_at: at)
    |> Oban.insert()
  end

  defp put_force(args, true), do: Map.put(args, "force", true)
  defp put_force(args, _not_forced), do: args

  defp alert(user_id, reason) do
    AdminAlerts.report(:account_deletion_stalled,
      summary: "Account deletion failed after every retry",
      reason: reason,
      context: %{user_id: user_id}
    )
  end
end
