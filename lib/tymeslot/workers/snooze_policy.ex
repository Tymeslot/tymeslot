defmodule Tymeslot.Workers.SnoozePolicy do
  @moduledoc """
  Bounds a worker's "not our fault yet, wait it out" snooze loop (an open
  circuit breaker, a rate limit) so a permanently failing dependency cannot
  snooze a job forever.

  Under Oban 2.23.1 (pinned; see
  `deferred/2026-08-29-oban-2-24-snooze-rollback-breaks-attempt-counters.md`),
  `{:snooze, n}` increments the job's `max_attempts` and leaves `attempt`
  alone, so a job's own `attempt >= max_attempts` safety valve never fires
  while it keeps snoozing: `max_attempts` grows to match. `attempt` itself
  still advances by one on every execution regardless of the outcome, so it
  remains a reliable, monotonically increasing counter to bound snoozing
  against directly, independent of Oban's own (perpetually receding)
  `max_attempts`.
  """

  @typedoc "What a caller should do with an attempt: keep waiting, or stop."
  @type outcome :: {:snooze, pos_integer()} | :exhausted

  @doc """
  Returns `{:snooze, seconds}` while `attempt` is under the `:max_snoozes`
  budget, and `:exhausted` once it is spent. The caller decides what
  "exhausted" means for it — discard loudly, or fall through to a
  give-up-and-purge path that already exists for genuine failures.

  Options:

    * `:max_snoozes` (required) — the attempt count at which to stop snoozing.
    * `:base_seconds` (required) — the snooze length before jitter, typically
      a circuit breaker's recovery window or a rate limit's backoff step.
    * `:jitter_seconds` — an upper bound for random extra seconds added to
      `base_seconds`, so a queue full of jobs snoozed during the same outage
      doesn't all wake in the same second. Defaults to `0` (no jitter).
  """
  @spec snooze_or_exhaust(pos_integer(), keyword()) :: outcome()
  def snooze_or_exhaust(attempt, opts) when is_integer(attempt) and attempt > 0 do
    max_snoozes = Keyword.fetch!(opts, :max_snoozes)

    if attempt >= max_snoozes do
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
