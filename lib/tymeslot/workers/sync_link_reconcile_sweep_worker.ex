defmodule Tymeslot.Workers.SyncLinkReconcileSweepWorker do
  @moduledoc """
  Fans out one `SyncLinkReconcileWorker` per link that is due for a re-diff.

  Separate from `FallbackSyncSweepWorker`, which it otherwise resembles closely,
  because the two reconcile different things. That one pulls *provider* state
  into the cache; this one reconciles Tymeslot's own mirror bookkeeping against
  the cache that sweep produced. Merging them would make mirroring wait on every
  calendar fetch finishing, and would put a mirror-side failure inside the job
  that keeps the event cache current.

  Its cron entry is at `20,50 * * * *` — every 30 minutes, deliberately off the
  `:00/:15/:30/:45` slots the rest of the crontab uses, so the two sweeps do not
  open their fan-outs into the same provider quota window.

  ## No provider I/O

  The sweep decides what is due from `last_reconciled_at` alone and does nothing
  else. Every calendar read and every provider write belongs to the per-link
  jobs it inserts, so a target that is down cannot slow the sweep down, and the
  sweep's own duration stays proportional to the number of links rather than to
  the state of anyone's calendar. `max_attempts: 1` follows from that: a cron
  job that fails has a successor twenty minutes behind it, and retrying a
  fan-out risks double-enqueueing what the first attempt already inserted.

  ## Batching

  Jobs go out in batches of 50, each batch scheduled one second after the one
  before via `scheduled_at`, copying `FallbackSyncSweepWorker`'s shape exactly.
  The stagger is `scheduled_at` rather than a sleep so the sweep does not hold
  its queue slot for the length of the fan-out. It matters more here than it
  looks: an organiser with several linked calendars has several links, all of
  which come due in the same sweep, and every reconcile job that runs at once
  enqueues write-backs against the same handful of provider accounts.

  `unique: [period: 1800]` matches the cron interval, so an overrunning sweep
  cannot be joined by its own successor.
  """
  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1,
    unique: [period: 1800]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Workers.SyncLinkReconcileWorker

  @batch_size 50
  @batch_stagger_seconds 1

  # A link is due half an hour after its last reconcile. Kept slightly under the
  # 30-minute cron interval so a sweep running a few seconds late does not find
  # every link one tick short of due and skip the entire round.
  @reconcile_interval_seconds 1_740

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    due = CalendarSyncLinkQueries.list_due_for_reconcile(@reconcile_interval_seconds)
    {scheduled, conflicts} = enqueue_batched(due)

    Logger.info("SyncLinkReconcileSweep complete",
      links_due: length(due),
      links_scheduled: scheduled,
      links_conflicted: conflicts
    )

    :ok
  end

  defp enqueue_batched(links) do
    now = DateTime.utc_now()

    links
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index()
    |> Enum.reduce({0, 0}, fn {batch, batch_index}, {scheduled, conflicts} ->
      {batch_scheduled, batch_conflicts} = enqueue_batch(batch, batch_index, now)
      {scheduled + batch_scheduled, conflicts + batch_conflicts}
    end)
  end

  defp enqueue_batch(batch, batch_index, now) do
    Enum.reduce(batch, {0, 0}, fn link, {scheduled, conflicts} ->
      case insert(link, batch_index, now) do
        :ok -> {scheduled + 1, conflicts}
        :conflict -> {scheduled, conflicts + 1}
        :error -> {scheduled, conflicts}
      end
    end)
  end

  defp insert(link, batch_index, now) do
    args = %{"sync_link_id" => link.id}

    case Oban.insert(SyncLinkReconcileWorker.new(args, stagger(batch_index, now))) do
      # The per-link worker is unique on `sync_link_id`, so a reconcile still
      # queued or running from the previous sweep swallows this one. That is the
      # desired outcome, not a failure: the run in flight is producing the same
      # diff this job would.
      {:ok, %Oban.Job{conflict?: true}} ->
        :conflict

      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue sync-link reconcile job",
          sync_link_id: link.id,
          error: inspect(reason)
        )

        :error
    end
  end

  defp stagger(0, _now), do: []

  defp stagger(batch_index, now),
    do: [scheduled_at: DateTime.add(now, batch_index * @batch_stagger_seconds, :second)]
end
