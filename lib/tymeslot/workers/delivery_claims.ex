defmodule Tymeslot.Workers.DeliveryClaims do
  @moduledoc """
  Makes a job's side effect happen at most once per job, however many times
  Oban runs that job.

  The Oban lifeline returns a job orphaned by a stopped node to `available`,
  so a job can run again after it already sent its email or posted its
  message, and before Oban recorded that it finished. Oban's `unique` option
  does not help: a rescued job is the same row coming back, not a new insert,
  so uniqueness is never consulted.

  `once/3` guards one effect by claiming it before performing it. The claim
  is keyed by the Oban job id, which a rescue does not change, plus a key
  naming the effect within the job, so a job that fans out to several
  recipients claims each of them separately.

  ## Why the claim comes first

  A marker written after the effect does not close the window, it only moves
  it: a node can stop between the send and the marker just as easily as
  between the send and Oban's acknowledgement. Claiming first means a rescued
  run always sees the claim and skips.

  The price is the opposite window. A node that stops after the claim and
  before the effect leaves a claim for something that never happened, and the
  rescued run skips it too. For an email or a chat message that trade is
  deliberate: a rescue is rare, and one lost notification is the lesser harm
  than every recipient getting two. Callers that must not lose the effect
  need a remote idempotency key as well (the webhook worker sends its delivery
  id for that reason).

  ## Ordinary retries still work

  The claim is kept only when the effect reports success (`:ok` or
  `{:ok, _}`). Any other result, and any raise, exit or throw, releases it,
  so an ordinary Oban retry after a failed send performs the effect again
  exactly as it did before claims existed. A snooze is not success either, so
  the snoozed run sends when it comes back.

  A job with no id (built by hand and called directly) cannot be rescued;
  `once/3` runs its effect unguarded.
  """

  require Logger

  alias Tymeslot.Workers.DeliveryClaims.DeliveryClaimQueries

  @doc """
  Deletes claims whose job Oban has pruned, returning how many. Run by
  `Tymeslot.Workers.ObanMaintenanceWorker`.
  """
  @spec prune_orphaned() :: non_neg_integer()
  defdelegate prune_orphaned, to: DeliveryClaimQueries, as: :delete_orphaned

  @type job_id :: integer() | nil

  @doc """
  Runs `effect` unless an earlier execution of the same job already claimed
  `key`, in which case it returns `:ok` without running it: from the job's
  point of view that effect is done.

  Otherwise returns whatever `effect` returns, releasing the claim unless that
  result is a success.
  """
  @spec once(Oban.Job.t() | job_id(), String.t(), (-> result)) :: result | :ok
        when result: term()
  def once(%Oban.Job{id: job_id}, key, effect), do: once(job_id, key, effect)

  def once(nil, _key, effect), do: effect.()

  def once(job_id, key, effect) when is_integer(job_id) and is_binary(key) do
    case DeliveryClaimQueries.claim(job_id, key) do
      :claimed ->
        run_claimed(job_id, key, effect)

      :already_claimed ->
        Logger.info("Skipping side effect already claimed by an earlier run of this job",
          job_id: job_id,
          effect_key: key
        )

        :ok
    end
  end

  defp run_claimed(job_id, key, effect) do
    result =
      try do
        effect.()
      catch
        kind, reason ->
          DeliveryClaimQueries.release(job_id, key)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    unless succeeded?(result), do: DeliveryClaimQueries.release(job_id, key)

    result
  end

  defp succeeded?(:ok), do: true
  defp succeeded?({:ok, _value}), do: true
  defp succeeded?(_result), do: false
end
