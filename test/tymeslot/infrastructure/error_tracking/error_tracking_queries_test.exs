defmodule Tymeslot.Infrastructure.ErrorTracking.ErrorTrackingQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :infrastructure
  @moduletag :queries

  import Ecto.Query

  alias ErrorTracker.Error
  alias ErrorTracker.Occurrence
  alias Tymeslot.Infrastructure.ErrorTracking.ErrorTrackingQueries

  describe "prune_resolved/2" do
    test "keeps calling the pruner until every old resolved error is gone" do
      old = for _n <- 1..3, do: insert_error(status: :resolved, last_seen_days_ago: 61)
      Enum.each(old, &insert_occurrence(&1, days_ago: 61))
      kept = insert_error(status: :resolved, last_seen_days_ago: 59)
      unresolved = insert_error(status: :unresolved, last_seen_days_ago: 61)

      assert ErrorTrackingQueries.prune_resolved(:timer.hours(24 * 60), batch_size: 1) == 3

      assert Repo.all(from e in Error, select: e.id, order_by: e.id) ==
               Enum.sort([kept.id, unresolved.id])

      assert Repo.all(Occurrence) == []
    end
  end

  describe "trim_unresolved_occurrences/3" do
    test "trims every unresolved error when both errors and occurrences span several batches" do
      cutoff = days_ago(30)
      errors = for _n <- 1..3, do: insert_error(status: :unresolved, last_seen_days_ago: 0)
      resolved = insert_error(status: :resolved, last_seen_days_ago: 31)

      for error <- [resolved | errors],
          days <- 31..50,
          do: insert_occurrence(error, days_ago: days)

      deleted =
        ErrorTrackingQueries.trim_unresolved_occurrences(cutoff, 5,
          error_batch_size: 2,
          occurrence_batch_size: 4
        )

      assert deleted == 3 * 15

      for error <- errors do
        assert occurrence_ages(error) == Enum.to_list(31..35)
      end

      # Resolved errors are the pruner's business, not the trim's.
      assert length(occurrence_ages(resolved)) == 20
    end
  end

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(), -days, :day)

  defp insert_error(opts) do
    Repo.insert!(%Error{
      kind: "Elixir.RuntimeError",
      reason: "boom",
      source_line: "lib/example.ex:#{System.unique_integer([:positive])}",
      source_function: "Example.run/0",
      fingerprint: Base.encode16(:crypto.strong_rand_bytes(16)),
      status: Keyword.fetch!(opts, :status),
      muted: false,
      last_occurrence_at: days_ago(Keyword.fetch!(opts, :last_seen_days_ago))
    })
  end

  defp insert_occurrence(%Error{} = error, days_ago: days) do
    Repo.insert!(%Occurrence{
      error_id: error.id,
      reason: "boom",
      context: %{},
      breadcrumbs: [],
      stacktrace: %ErrorTracker.Stacktrace{lines: []},
      inserted_at: days_ago(days)
    })
  end

  defp occurrence_ages(%Error{id: id}) do
    now = DateTime.utc_now()

    from(o in Occurrence, where: o.error_id == ^id, select: o.inserted_at)
    |> Repo.all()
    |> Enum.map(&DateTime.diff(now, &1, :day))
    |> Enum.sort()
  end
end
