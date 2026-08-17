defmodule Tymeslot.Integrations.Calendar.SyncLink.WriteBackQueries do
  @moduledoc """
  Reads the write-back queue itself, which no other query module covers.

  There is one caller and one question: what moved occurrences is the pending
  job for this `{link, source_uid}` already carrying? It lives here rather than
  in `WriteBack` because persistence flows through query modules, and rather
  than in `CalendarSyncLinkQueries` because the row being read is an Oban job
  rather than anything the sync-link domain owns.
  """

  import Ecto.Query, only: [where: 3, select: 3, limit: 2]

  alias Oban.Worker
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncLinkWriteBackWorker

  @pending_states ["available", "scheduled", "retryable"]

  @doc """
  The `moved` args of the pending write-back for this pair, or `nil`.

  Only the states a job has not started in: an executing job has already read
  its args, so what it carries can no longer be preserved into anything.
  """
  @spec pending_moves(integer(), String.t()) :: [map()] | nil
  def pending_moves(sync_link_id, source_uid)
      when is_integer(sync_link_id) and is_binary(source_uid) do
    Oban.Job
    |> where([j], j.worker == ^Worker.to_string(SyncLinkWriteBackWorker))
    |> where([j], j.state in ^@pending_states)
    |> where([j], fragment("? ->> 'sync_link_id' = ?", j.args, ^to_string(sync_link_id)))
    |> where([j], fragment("? ->> 'source_uid' = ?", j.args, ^source_uid))
    |> select([j], fragment("? -> 'moved'", j.args))
    |> limit(1)
    |> Repo.one()
  end
end
