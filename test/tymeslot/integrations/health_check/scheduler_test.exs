defmodule Tymeslot.Integrations.HealthCheck.SchedulerTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.HealthCheck.Scheduler

  describe "due_for_check?/2" do
    test "returns true for integrations never checked" do
      health_state = %{last_check_at: nil, backoff_ms: :timer.minutes(5)}
      now = DateTime.utc_now()

      assert Scheduler.due_for_check?(health_state, now) == true
    end

    test "returns true when backoff period has elapsed" do
      last_check_at = DateTime.add(DateTime.utc_now(), -6, :minute)
      health_state = %{last_check_at: last_check_at, backoff_ms: :timer.minutes(5)}
      now = DateTime.utc_now()

      assert Scheduler.due_for_check?(health_state, now) == true
    end

    test "returns false when backoff period has not elapsed" do
      last_check_at = DateTime.add(DateTime.utc_now(), -3, :minute)
      health_state = %{last_check_at: last_check_at, backoff_ms: :timer.minutes(5)}
      now = DateTime.utc_now()

      assert Scheduler.due_for_check?(health_state, now) == false
    end

    test "returns true when exactly at backoff boundary" do
      last_check_at = DateTime.add(DateTime.utc_now(), -5, :minute)
      health_state = %{last_check_at: last_check_at, backoff_ms: :timer.minutes(5)}
      now = DateTime.utc_now()

      assert Scheduler.due_for_check?(health_state, now) == true
    end

    test "handles longer backoff periods correctly" do
      last_check_at = DateTime.add(DateTime.utc_now(), -45, :minute)
      health_state = %{last_check_at: last_check_at, backoff_ms: :timer.hours(1)}
      now = DateTime.utc_now()

      assert Scheduler.due_for_check?(health_state, now) == false
    end
  end

  describe "scheduled_at_with_jitter/0" do
    test "returns a DateTime in the future" do
      now = DateTime.utc_now()
      scheduled = Scheduler.scheduled_at_with_jitter()

      assert DateTime.compare(scheduled, now) in [:gt, :eq]
    end

    test "adds jitter within expected range (0-30 seconds)" do
      now = DateTime.utc_now()
      scheduled = Scheduler.scheduled_at_with_jitter()

      diff_ms = DateTime.diff(scheduled, now, :millisecond)

      # Should be between 0 and 30 seconds
      assert diff_ms >= 0
      assert diff_ms <= 30_000
    end

    test "produces varying jitter values across multiple calls" do
      results =
        for _iteration <- 1..10 do
          now = DateTime.utc_now()
          scheduled = Scheduler.scheduled_at_with_jitter()
          DateTime.diff(scheduled, now, :millisecond)
        end

      # Should have at least some variation (not all the same)
      unique_values = Enum.uniq(results)
      assert length(unique_values) > 1
    end
  end
end
