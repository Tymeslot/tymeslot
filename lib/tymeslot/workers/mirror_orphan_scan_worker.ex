defmodule Tymeslot.Workers.MirrorOrphanScanWorker do
  @moduledoc """
  Daily scan for mirror placeholders that no mapping row claims.

  `SyncLink.OrphanScan` can answer "is a busy block sitting on someone's
  calendar with nothing able to update or remove it?", but until this worker it
  had no way to be asked: no schedule, no route, no task. A detector nothing
  invokes reports nothing, which is indistinguishable from a system with no
  orphans — and the whole point of writing detection before repair was to learn
  which of those two we are in.

  ## Why the question is still open

  Every mirror row is cascaded away by the database when its link or either of
  its integrations is deleted — `on_delete: :delete_all` on both foreign keys
  (`20260813090100_create_calendar_sync_mirrors.exs`) — while the placeholder it
  named stays on the provider. `Calendar.Deletion` therefore withdraws first and
  abandons the disconnect if it cannot, and that guard is what keeps the normal
  path safe. It is a guard on one path, not a property of the schema: the rows
  go the moment anything else deletes a link or an integration, and
  `Engine.persist_or_compensate/5`'s compensating delete is documented
  best-effort and returns `:ok` when the provider refuses it.

  So this reports rather than repairs, for the reason `OrphanScan` gives:
  rebuilding a row means guessing which source a placeholder belonged to, and a
  wrong guess writes to a real calendar. What runs on a schedule is only the
  question.

  ## Why daily, and why per organiser

  Daily at 04:15 UTC, in the quiet band the other reconciliation scans use and
  off their exact slots. An orphan does not decay — nothing else will notice it,
  which is the definition of the state — so scanning more often buys nothing but
  load. It is placed after `CalendarCachePruneWorker` (03:30) deliberately: the
  scan reads the event cache, and reading it before the prune means reporting
  identities that are about to be dropped anyway.

  One job per organiser rather than one job for the installation. The scan's
  unit is the user — a placeholder is unclaimed relative to everything that user
  owns — and fanning out keeps one organiser's slow scan from delaying the rest,
  the same shape `SyncLinkReconcileSweepWorker` and `FallbackSyncSweepWorker`
  use. Only organisers with at least one link are scanned; the rest have no
  mirrors and nothing to derive from.

  ## No provider I/O

  The scan reads `provider_calendar_events` and `calendar_sync_mirrors` and
  calls nothing. That is what makes a daily pass over every organiser
  affordable, and it is why `max_attempts: 1` is right: a database read that
  fails has a successor twenty-four hours behind it, and there is no partial
  provider state a retry would need to finish.
  """
  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 1,
    unique: [period: 3600]

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.SyncLink.OrphanScan

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) when is_integer(user_id) do
    OrphanScan.report_for_user(user_id)
    :ok
  end

  # The sweep. No args means "fan out", which keeps the cron entry free of a
  # payload and lets the same module answer both halves.
  def perform(%Oban.Job{}) do
    user_ids = CalendarSyncLinkQueries.list_user_ids_with_links()
    scheduled = Enum.count(user_ids, &(insert(&1) == :ok))

    Logger.info("Mirror orphan scan sweep complete",
      users_with_links: length(user_ids),
      users_scheduled: scheduled
    )

    :ok
  end

  defp insert(user_id) do
    case Oban.insert(__MODULE__.new(%{"user_id" => user_id})) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue mirror orphan scan",
          user_id: user_id,
          error: inspect(reason)
        )

        :error
    end
  end
end
