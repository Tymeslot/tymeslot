defmodule Tymeslot.Test.CronUniqueness do
  @moduledoc """
  Finds crontab entries whose worker would swallow its own next scheduled run.

  Oban's uniqueness counts from the previous job's insertion, and a completed
  job still counts unless the worker narrows its states. A unique period as
  long as the gap to the next run drops that run whenever the cron plugin
  inserts it a moment early, so every such period must fall short of the
  schedule's shortest gap. Schedules need not be evenly spaced
  (`"0 2,20 * * *"`, `"0 */5 * * *"`), so the gaps are measured across eight
  days of runs rather than once.
  """

  alias Oban.Cron.Expression

  @start ~U[2026-01-05 00:00:30Z]
  @window_seconds 8 * 24 * 3600
  @max_runs 5_000

  @doc """
  The `{worker, period, shortest_gap}` of every entry in `crontab` whose
  worker's unique period counts completed jobs and is not shorter than its
  schedule's shortest gap.
  """
  @spec offenders(list()) :: [{module(), pos_integer(), pos_integer()}]
  def offenders(crontab) do
    for entry <- crontab,
        {schedule, worker} = {elem(entry, 0), elem(entry, 1)},
        period = completed_counting_period(worker),
        period != nil,
        gap = shortest_gap(schedule),
        period >= gap,
        do: {worker, period, gap}
  end

  @doc "The shortest gap in seconds between consecutive runs of `schedule`."
  @spec shortest_gap(String.t()) :: pos_integer()
  def shortest_gap(schedule) do
    {:ok, expression} = Expression.parse(schedule)
    first = Expression.next_at(expression, @start)
    stop = DateTime.add(first, @window_seconds)

    first
    |> Stream.iterate(&Expression.next_at(expression, DateTime.add(&1, 60)))
    |> Stream.take_while(&(DateTime.compare(&1, stop) != :gt))
    |> Stream.take(@max_runs)
    |> Stream.chunk_every(2, 1, :discard)
    |> Enum.map(fn [earlier, later] -> DateTime.diff(later, earlier) end)
    |> Enum.min()
  end

  defp completed_counting_period(worker) do
    unique = Keyword.get(worker.__opts__(), :unique) || []
    states = Keyword.get(unique, :states, :all)

    counts_completed? =
      states in [:all, :successful] or (is_list(states) and :completed in states)

    case Keyword.get(unique, :period) do
      period when is_integer(period) and counts_completed? -> period
      _infinite_or_ignored -> nil
    end
  end
end
