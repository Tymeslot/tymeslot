defmodule Tymeslot.Integrations.Calendar.Shared.CalendarFetchAggregateTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate
  alias Tymeslot.Integrations.Calendar.Shared.FetchAggregate.Outcome

  describe "collect/3" do
    test "aggregates events from successes, drops absent sources, and records failures" do
      results = [
        {:success, ["event-1", "event-2"]},
        {:absent, "deleted"},
        {:failure, "cal-2", :timeout}
      ]

      outcome =
        FetchAggregate.collect(results, fn
          {:success, events} -> {:ok, events}
          {:absent, _source} -> :absent
          {:failure, source, reason} -> {:error, source, reason}
        end)

      assert %Outcome{
               events: ["event-1", "event-2"],
               attempted: 3,
               succeeded: 1,
               failed: [%{source: "cal-2", reason: :timeout}]
             } = outcome
    end

    test "merges a nested outcome's events/attempted/succeeded/failed into the parent instead of counting it as one source" do
      nested_outcome = %Outcome{
        events: [:nested_event],
        attempted: 6,
        succeeded: 5,
        failed: [%{source: "cal-9", reason: :timeout}]
      }

      results = [
        {:success, [:top_event]},
        {:aggregate, nested_outcome}
      ]

      outcome =
        FetchAggregate.collect(results, fn
          {:success, events} -> {:ok, events}
          {:aggregate, nested} -> {:aggregate, nested}
        end)

      assert %Outcome{
               events: [:top_event, :nested_event],
               attempted: 7,
               succeeded: 6,
               failed: [%{source: "cal-9", reason: :timeout}]
             } = outcome
    end
  end

  describe "require_complete/1 (availability path — fails closed)" do
    test "returns events when every source succeeded" do
      outcome = %Outcome{events: [:a, :b], attempted: 2, succeeded: 2, failed: []}

      assert {:ok, [:a, :b]} = FetchAggregate.require_complete(outcome)
    end

    test "refuses a partial result rather than silently dropping the failed source's busy time" do
      outcome = %Outcome{
        events: [:a],
        attempted: 2,
        succeeded: 1,
        failed: [%{source: "cal-2", reason: :timeout}]
      }

      assert {:error, :some_calendars_unavailable} = FetchAggregate.require_complete(outcome)
    end

    test "reports all_calendars_unavailable when every source failed" do
      outcome = %Outcome{
        events: [],
        attempted: 2,
        succeeded: 0,
        failed: [
          %{source: "cal-1", reason: :timeout},
          %{source: "cal-2", reason: :network_error}
        ]
      }

      assert {:error, :all_calendars_unavailable} = FetchAggregate.require_complete(outcome)
    end

    test "returns an empty result when every source is confirmed absent" do
      # No hard failures, and no usable source either — but a confirmed-absent
      # source is a known-empty diary, not a gap, so this is a clean {:ok, []}
      # rather than a fail-closed refusal.
      outcome = %Outcome{events: [], attempted: 2, succeeded: 0, failed: []}

      assert {:ok, []} = FetchAggregate.require_complete(outcome)
    end

    test "returns an empty result when nothing was attempted at all" do
      outcome = %Outcome{events: [], attempted: 0, succeeded: 0, failed: []}

      assert {:ok, []} = FetchAggregate.require_complete(outcome)
    end
  end
end
