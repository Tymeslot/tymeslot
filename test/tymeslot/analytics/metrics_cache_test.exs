defmodule Tymeslot.Analytics.MetricsCacheTest do
  # async: false — exercises the shared, app-supervised ETS table and clears it.
  use ExUnit.Case, async: false

  @moduletag :analytics

  alias Tymeslot.Analytics.MetricsCache

  # Synthetic, high user ids that no factory-created user will collide with.
  @user_a 9_000_001
  @user_b 9_000_002

  setup do
    MetricsCache.clear_all()
    on_exit(&MetricsCache.clear_all/0)
    :ok
  end

  test "computes once per {user_id, range_days, time_zone} and serves the cached value after" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    compute = fn ->
      Agent.update(counter, &(&1 + 1))
      :computed
    end

    assert MetricsCache.fetch(@user_a, 30, "Etc/UTC", compute) == :computed
    assert MetricsCache.fetch(@user_a, 30, "Etc/UTC", compute) == :computed
    assert Agent.get(counter, & &1) == 1
  end

  test "isolates cache entries by user_id" do
    assert MetricsCache.fetch(@user_a, 30, "Etc/UTC", fn -> :user_a end) == :user_a
    assert MetricsCache.fetch(@user_b, 30, "Etc/UTC", fn -> :user_b end) == :user_b
  end

  test "isolates cache entries by range window" do
    assert MetricsCache.fetch(@user_a, 7, "Etc/UTC", fn -> :seven end) == :seven
    assert MetricsCache.fetch(@user_a, 30, "Etc/UTC", fn -> :thirty end) == :thirty
  end

  # The visits-by-day series is bucketed in the organizer's zone, so a zone
  # change must recompute rather than serve the previous zone's buckets.
  test "isolates cache entries by time zone" do
    assert MetricsCache.fetch(@user_a, 30, "Etc/UTC", fn -> :utc end) == :utc
    assert MetricsCache.fetch(@user_a, 30, "Europe/Tallinn", fn -> :tallinn end) == :tallinn
  end

  test "invalidate/3 drops only the given window" do
    MetricsCache.fetch(@user_a, 30, "Etc/UTC", fn -> :stale end)
    MetricsCache.fetch(@user_a, 30, "Europe/Tallinn", fn -> :kept end)

    MetricsCache.invalidate(@user_a, 30, "Etc/UTC")

    assert MetricsCache.fetch(@user_a, 30, "Etc/UTC", fn -> :fresh end) == :fresh
    assert MetricsCache.fetch(@user_a, 30, "Europe/Tallinn", fn -> :recomputed end) == :kept
  end
end
