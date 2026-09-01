defmodule Tymeslot.Workers.SnoozePolicy do
  @moduledoc """
  Bounds a worker's "not our fault yet, wait it out" snooze loop (an open
  circuit breaker, a rate limit) so a permanently failing dependency cannot
  snooze a job forever.

  A snooze loop cannot be bounded by Oban's own `max_attempts`, and the reason
  differs by version. Up to Oban 2.23 `{:snooze, n}` incremented `max_attempts`
  while `attempt` kept its ordinary once-per-execution increment, so a job's
  `attempt >= max_attempts` safety valve never fired: `max_attempts` grew to
  match. From 2.24 it is the other way round — `attempt` is rolled back and
  `max_attempts` preserved — so `attempt` never climbs to meet it either.
  Either way the job snoozes forever unless the worker keeps the count itself.

  `executions/1` is that count, and it is what every snooze bound here is
  measured against.
  """

  @typedoc "What a caller should do with an execution: keep waiting, or stop."
  @type outcome :: {:snooze, pos_integer()} | :exhausted

  @doc """
  How many times Oban has handed `job` to `perform/1`: genuine attempts and
  snoozes alike.

  This, not `job.attempt`, is what a snooze loop must measure itself against.
  It is deliberately the same number on either side of Oban 2.24: before it,
  `attempt` already counted snoozes and `meta["snoozed"]` was absent; after it,
  the snoozes moved out of `attempt` and into `meta["snoozed"]`, and the two
  halves add back up. A worker bounded by this behaves identically across the
  bump.
  """
  @spec executions(Oban.Job.t()) :: pos_integer()
  def executions(%Oban.Job{attempt: attempt, meta: meta}), do: attempt + snoozes(meta)

  # Oban writes an integer, but `meta` is a JSONB map a caller may also set, so
  # an unusable value counts as no snoozes rather than crashing the job.
  defp snoozes(%{"snoozed" => count}) when is_integer(count) and count > 0, do: count
  defp snoozes(_meta), do: 0

  @doc """
  Returns `{:snooze, seconds}` while `executions` is under the `:max_snoozes`
  budget, and `:exhausted` once it is spent. The caller decides what
  "exhausted" means for it — discard loudly, or fall through to a
  give-up-and-purge path that already exists for genuine failures.

  `executions` comes from `executions/1`; passing `job.attempt` directly is the
  bug this module exists to prevent.

  Options:

    * `:max_snoozes` (required) — the execution count at which to stop snoozing.
    * `:base_seconds` (required) — the snooze length before jitter, typically
      a circuit breaker's recovery window or a rate limit's backoff step.
    * `:jitter_seconds` — an upper bound for random extra seconds added to
      `base_seconds`, so a queue full of jobs snoozed during the same outage
      doesn't all wake in the same second. Defaults to `0` (no jitter).
  """
  @spec snooze_or_exhaust(pos_integer(), keyword()) :: outcome()
  def snooze_or_exhaust(executions, opts) when is_integer(executions) and executions > 0 do
    max_snoozes = Keyword.fetch!(opts, :max_snoozes)

    if executions >= max_snoozes do
      :exhausted
    else
      base_seconds = Keyword.fetch!(opts, :base_seconds)
      jitter_seconds = Keyword.get(opts, :jitter_seconds, 0)
      {:snooze, base_seconds + jitter(jitter_seconds)}
    end
  end

  defp jitter(0), do: 0
  defp jitter(max) when is_integer(max) and max > 0, do: :rand.uniform(max)
end
