defmodule Tymeslot.Integrations.Calendar.SyncLink.WriteBack do
  @moduledoc """
  Enqueues the mirror write that follows a source event changing.

  Split out of the sync path for the same reason `ColourWriteBack` is split out
  of the calendar context: this is the enqueue mechanism, not a domain entry
  point, and keeping it here means the sync path holds one call rather than
  Oban's vocabulary.

  ## Why this always returns `:ok`

  The caller is `Sync.post_commit_reconciliation/2`, which runs after an inbound
  sync has already committed. Surfacing an enqueue failure there would give the
  sync worker an error for work that succeeded, and there is nothing useful for
  it to do about it: the cache is correct, the mirror is merely late, and the
  reconcile sweep finds a source with no matching mirror and writes it. A
  mirror write is best-effort by design — a target calendar that is slow, down,
  or over quota must never be able to fail an inbound sync of a different
  calendar.

  So a failed enqueue is logged and swallowed. What is not acceptable is a
  failure that leaves no trace, which is the reason for the log line rather
  than a bare `:ok`.
  """

  require Logger

  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  @typedoc """
  `:upsert` covers both create and update — which one it is depends on whether a
  mapping row exists at the time the job runs, which the enqueue site cannot
  know and should not guess. `:delete` withdraws a placeholder whose source is
  gone.
  """
  @type operation :: :upsert | :delete

  @doc """
  Enqueues one mirror write.

  `replace: [:args]` matters here for the same reason it does on the colour
  write-back, and one case more. `unique` alone keeps the *first* pending job
  and drops the newer enqueue, so an event edited twice before the queue drains
  would mirror the first edit and silently discard the second. Worse, an event
  edited and then deleted would keep the upsert and drop the delete, leaving a
  placeholder on the target for an event that no longer exists. Replacing the
  args means the pending job always carries the latest intent.
  """
  @spec enqueue(integer(), String.t(), operation()) :: :ok
  def enqueue(sync_link_id, source_uid, operation)
      when is_integer(sync_link_id) and is_binary(source_uid) and operation in [:upsert, :delete] do
    %{
      "sync_link_id" => sync_link_id,
      "source_uid" => source_uid,
      "operation" => Atom.to_string(operation)
    }
    |> SyncLinkWriteBackWorker.new(replace: [:args])
    |> Oban.insert()
    |> log_enqueue_error(sync_link_id, source_uid)

    :ok
  end

  defp log_enqueue_error({:ok, _job}, _sync_link_id, _source_uid), do: :ok

  defp log_enqueue_error({:error, reason}, sync_link_id, source_uid) do
    Logger.warning("Failed to enqueue calendar sync-link write-back",
      sync_link_id: sync_link_id,
      source_uid: source_uid,
      reason: inspect(reason)
    )

    :ok
  end
end
