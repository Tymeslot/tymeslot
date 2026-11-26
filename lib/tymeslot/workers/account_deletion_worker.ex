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
  next day. A refusal that persists would otherwise repeat daily with nothing
  but a log line, so it raises an `:account_deletion_stalled` admin alert:
  on every attempt that Stripe refuses with an error retrying cannot fix,
  and on the last attempt of each run for any other refusal. The alert is
  deduplicated per account for 24 hours, so the operator hears once a day
  however many attempts fail. A deletion re-requested while the old job is
  still executing conflicts with it, and gets its job from the next sweep.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [period: :infinity, keys: [:user_id], states: :incomplete]

  @exhausted_summary "Account deletion failed after every retry"
  @stripe_refused_summary "Account deletion refused by Stripe; it will keep retrying until the cause is fixed"

  alias Tymeslot.Auth.AccountDeletion
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Integrations.Stripe.Error, as: StripeError

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args} = job) when is_integer(user_id) do
    case AccountDeletion.run_scheduled_deletion(user_id, force: Map.get(args, "force") == true) do
      {:ok, _outcome} ->
        :ok

      {:snooze, seconds} ->
        {:snooze, seconds}

      {:error, reason} ->
        cond do
          permanent_stripe_error?(reason) ->
            alert(user_id, reason, @stripe_refused_summary)

          job.attempt >= job.max_attempts ->
            alert(user_id, reason, @exhausted_summary)

          true ->
            :ok
        end

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

  # Retrying cannot fix a refusal Stripe will repeat, so the operator hears
  # at once; the deletion is still retried, never cancelled.
  defp permanent_stripe_error?(%StripeError{} = error), do: not StripeError.retryable?(error)
  defp permanent_stripe_error?(_reason), do: false

  defp alert(user_id, reason, summary) do
    AdminAlerts.report(:account_deletion_stalled,
      summary: summary,
      reason: reason,
      context: put_request_id(%{user_id: user_id}, reason)
    )
  end

  defp put_request_id(context, %StripeError{request_id: id}) when is_binary(id),
    do: Map.put(context, :stripe_request_id, id)

  defp put_request_id(context, _reason), do: context
end
