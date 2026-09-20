defmodule Tymeslot.Integrations.HealthCheck.SchedulerTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  import Tymeslot.Test.ClockHelpers

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

  # Reading "now" through the clock is what makes the window exact: measured
  # against a separate `DateTime.utc_now()` in the test, whatever elapsed
  # between the two reads counted as jitter, so a slow run could exceed the
  # cap the assertion is there to enforce.
  describe "scheduled_at_with_jitter/0" do
    setup do
      now = ~U[2026-09-20 12:00:00Z]
      freeze_clock(now)
      {:ok, now: now}
    end

    test "returns a DateTime in the future", %{now: now} do
      assert DateTime.compare(Scheduler.scheduled_at_with_jitter(), now) in [:gt, :eq]
    end

    test "adds jitter within expected range (0-30 seconds)", %{now: now} do
      diff_ms = DateTime.diff(Scheduler.scheduled_at_with_jitter(), now, :millisecond)

      assert diff_ms >= 0
      assert diff_ms <= 30_000
    end

    test "produces varying jitter values across multiple calls", %{now: now} do
      results =
        for _iteration <- 1..10 do
          DateTime.diff(Scheduler.scheduled_at_with_jitter(), now, :millisecond)
        end

      # Should have at least some variation (not all the same)
      assert results |> Enum.uniq() |> length() > 1
    end
  end
end
