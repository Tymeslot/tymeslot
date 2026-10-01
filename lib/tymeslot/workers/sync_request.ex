defmodule Tymeslot.Workers.SyncRequest do
  @moduledoc """
  A sync asked for because the provider may hold something the cache does
  not: the dashboard's Refresh, or a write that dropped a series' cached rows
  for a sync to bring back (`Tymeslot.CalendarGrid.SeriesEdit.request_sync/2`).

  The Google, Outlook and CalDAV sync workers are unique per integration over
  every state up to and including `:executing`, so a webhook or the fallback
  sweep folds into whatever sync of the integration is already queued or
  running, and an integration never has more than one sync job. A request
  cannot simply fold in the same way: a sync already running may have read
  the provider before the change the request is about, and would finish
  without it.

  So a request is inserted with `replace:`, and on a conflict rewrites the
  args of the job already there instead, stamped with when it was made
  (`"requested_at"`):

    * a waiting job runs with the request's args, which for CalDAV carry the
      full fetch, so a delta sync already waiting cannot absorb the stronger
      fetch;
    * a scheduled one, such as the sweep's jittered full fetch, is brought
      forward to now;
    * a retryable one (already failed once and waiting out its backoff, up
      to 8 minutes on Outlook) is brought forward to now too, so the request
      does not wait out someone else's backoff, and is not lost with the job
      if that backoff ladder then runs out and the job is discarded;
    * a running one cannot take new args mid-run, so the worker, once its run
      has succeeded, rereads its row (`rerun_if_requested/2`). Args that are
      no longer the ones it started with mean a request came in meanwhile,
      and the job snoozes: the same job runs again straight after, never
      beside itself, reading the provider afresh.

  A request is matched against a waiting (available/scheduled/retryable) job
  of any age (`period: :infinity`), so it folds into one rather than starting
  a second beside it. An `:executing` row is matched the same way, unless it
  is older than `@orphaned_executing_after_seconds`: nothing here runs
  anywhere near that long, so a row that old did not survive its node (the
  Lifeline in `config/runtime.exs` only rescues it after 6 hours) and folding
  into it would otherwise swallow the request until the rescue. Such a
  request instead gets a job of its own.
  """

  alias Tymeslot.Jobs

  @replace [
    available: [:args],
    scheduled: [:args, :scheduled_at],
    retryable: [:args, :scheduled_at],
    executing: [:args]
  ]

  # How long a job that was asked to run again while running waits first.
  @rerun_after_seconds 1

  # An `:executing` row this old cannot still be a sync in progress; see the
  # moduledoc.
  @orphaned_executing_after_seconds 1800

  @doc """
  Inserts a request of `worker`, a sync worker unique per integration, with
  `args`.
  """
  @spec insert(module(), map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def insert(worker, args) do
    now = DateTime.utc_now()
    stamped_args = Map.put(args, "requested_at", DateTime.to_iso8601(now))
    unique = Keyword.put(worker.__opts__()[:unique], :period, :infinity)

    stamped_args
    |> worker.new(state: "available", scheduled_at: now, unique: unique, replace: @replace)
    |> Oban.insert()
    |> retry_past_orphaned_executing(worker, stamped_args, now)
  end

  # A conflict folded into an `:executing` row too old to still be running:
  # insert again without matching `:executing`, so the request gets a job of
  # its own instead of waiting for the Lifeline to rescue that row.
  defp retry_past_orphaned_executing(
         {:ok,
          %Oban.Job{
            conflict?: true,
            state: "executing",
            attempted_at: %DateTime{} = attempted_at
          }} = result,
         worker,
         stamped_args,
         now
       ) do
    if DateTime.diff(now, attempted_at, :second) > @orphaned_executing_after_seconds do
      unique =
        worker.__opts__()[:unique]
        |> Keyword.put(:period, :infinity)
        |> Keyword.update!(:states, &List.delete(&1, :executing))

      stamped_args
      |> worker.new(state: "available", scheduled_at: now, unique: unique, replace: @replace)
      |> Oban.insert()
    else
      result
    end
  end

  defp retry_past_orphaned_executing(result, _worker, _stamped_args, _now), do: result

  @doc """
  Turns a run's successful `result` into a snooze when a request rewrote the
  job's args while it ran, so the job runs again after this run; any other
  result is returned as it is (a retry already rereads the row).
  """
  @spec rerun_if_requested(term(), Oban.Job.t()) :: term()
  def rerun_if_requested(:ok, %Oban.Job{args: args} = job) do
    case Jobs.get_current_args(job) do
      replaced when is_map(replaced) and replaced != args -> {:snooze, @rerun_after_seconds}
      _unchanged_or_gone -> :ok
    end
  end

  def rerun_if_requested(result, _job), do: result
end
