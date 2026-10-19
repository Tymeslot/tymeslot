defmodule Tymeslot.Test.RaceConductor do
  @moduledoc """
  Stages races between database transactions on real connections.

  The sandbox cannot show these races: it gives a test one connection, so
  "concurrent" transactions queue on it and each sees the previous one
  committed, whether or not the code takes the locks it relies on. Each
  contender run by `race/1` therefore runs on its own connection
  (`Ecto.Adapters.SQL.Sandbox.unboxed_run/2`) and commits for real, so a
  module using this must be synchronous and must delete what it committed
  in `on_exit`.

  The races are staged rather than left to timing. A contender is given a
  `hold` function to call inside its transaction; the call parks it. The
  conductor releases the parked contenders only when every unfinished one is
  either parked or waiting on a database lock, that is, when nobody can get
  any further before somebody commits. With the locks in place a single
  contender parks at a time and the rest queue behind it; without them every
  contender reads the same state, parks, and all of them commit.

  Where the code under test offers no hook to call `hold` from, a contender
  can arm itself with `arm/2` to park right after a given query instead.
  A contender armed with `must_park: true` that finishes still armed never
  reached that query, so the race it was meant to stage never happened:
  `race/1` fails the test rather than let it pass over a race not run. It is
  opt-in because a contender queued behind a lock may rightly give up before
  the query (a booking loser told the slot is taken, say).
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Repo

  @park_key :race_conductor_hold

  @doc """
  Runs each contender (a function of `hold`) on its own connection and
  returns each one's result, in order. A raised error (a deadlock Postgres
  broke by aborting one side, say) comes back as `{:raised, error}`. Fails
  the test if a contender armed with `must_park: true` finished without
  parking.
  """
  @spec race([(function() -> term())]) :: [term()]
  def race(contenders) do
    conductor = self()

    hold = fn _arg ->
      send(conductor, {:parked, self()})

      receive do
        :release -> {:ok, :released}
      end
    end

    tasks =
      Enum.map(contenders, fn contender ->
        Task.async(fn ->
          unboxed(fn ->
            result =
              try do
                contender.(hold)
              rescue
                error -> {:raised, error}
              end

            {result, match?({_hold, _match, true}, Process.get(@park_key))}
          end)
        end)
      end)

    outcomes =
      tasks
      |> conduct(%{}, [], System.monotonic_time(:millisecond) + 30_000)
      |> then(fn results -> Enum.map(tasks, &Map.fetch!(results, &1.ref)) end)

    unparked = for {{_result, true}, index} <- Enum.with_index(outcomes, 1), do: index

    if unparked != [] do
      flunk("""
      the race was not staged: contender #{Enum.join(unparked, ", ")}, armed \
      with must_park, finished without reaching the query it was to park at\
      """)
    end

    Enum.map(outcomes, &elem(&1, 0))
  end

  @doc """
  Lets contenders park at a query of their choosing (see `arm/2`), for code
  under test that offers no hook to call `hold` from. Detached when the test
  exits.
  """
  @spec attach_parking() :: :ok
  def attach_parking do
    handler_id = "race-conductor-parking-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, _config -> maybe_park(metadata) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  @doc """
  Arms the calling contender to park, once, right after the first query of
  its own for which `match` (given the query's telemetry metadata) returns
  true. Needs `attach_parking/0`.

  With `must_park: true`, `race/1` fails the test if the contender finishes
  without having parked, so a query the match no longer recognises cannot
  leave the race silently unstaged.
  """
  @spec arm(function(), (map() -> boolean()), keyword()) :: :ok
  def arm(hold, match, opts \\ []) do
    Process.put(@park_key, {hold, match, Keyword.get(opts, :must_park, false)})
    :ok
  end

  @doc "Matches an insert into `table`."
  @spec insert_into(String.t()) :: (map() -> boolean())
  def insert_into(table),
    do: &(&1[:source] == table and String.starts_with?(&1[:query], "INSERT"))

  @doc "Matches a `FOR UPDATE` read of `table`."
  @spec lock_of(String.t()) :: (map() -> boolean())
  def lock_of(table), do: &(&1[:source] == table and &1[:query] =~ "FOR UPDATE")

  @doc "Matches the taking of an advisory transaction lock."
  @spec advisory_lock() :: (map() -> boolean())
  def advisory_lock, do: &(&1[:query] =~ "pg_advisory_xact_lock")

  defp maybe_park(metadata) do
    with {hold, match, _must_park} <- Process.get(@park_key),
         true <- match.(metadata) do
      Process.delete(@park_key)
      {:ok, :released} = hold.(nil)
    end
  end

  @doc "Runs `fun` on a connection of its own, outside the sandbox."
  @spec unboxed((-> result)) :: result when result: term()
  def unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp conduct(pending, results, parked, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: flunk("race did not settle")

    {pending, results} = collect_finished(pending, results)
    parked = drain_parked(parked)

    cond do
      pending == [] ->
        results

      parked != [] and length(parked) + lock_waiters() >= length(pending) ->
        Enum.each(parked, &send(&1, :release))
        conduct(pending, results, [], deadline)

      true ->
        receive do
          {:parked, pid} -> conduct(pending, results, [pid | parked], deadline)
        after
          10 -> conduct(pending, results, parked, deadline)
        end
    end
  end

  defp collect_finished(pending, results) do
    Enum.reduce(pending, {[], results}, fn task, {still_pending, results} ->
      case Task.yield(task, 0) do
        {:ok, result} -> {still_pending, Map.put(results, task.ref, result)}
        nil -> {[task | still_pending], results}
      end
    end)
  end

  defp drain_parked(parked) do
    receive do
      {:parked, pid} -> drain_parked([pid | parked])
    after
      0 -> parked
    end
  end

  defp lock_waiters do
    %{rows: [[count]]} =
      unboxed(fn ->
        SQL.query!(
          Repo,
          "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'",
          []
        )
      end)

    count
  end
end
