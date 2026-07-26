defmodule Tymeslot.Integrations.HealthCheck.MonitorHealthStateTest do
  @moduledoc """
  Covers the health-state machine itself: the initial state, the status
  thresholds, and how a probe outcome (success, transient error, hard error)
  folds into the next state.

  Transition classification lives in `MonitorTransitionTest`; persistence and
  reporting live in `MonitorPersistenceTest`.
  """
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.HealthCheck.Monitor

  describe "initial_state/0" do
    test "returns a healthy initial state" do
      state = Monitor.initial_state()

      assert state.failures == 0
      assert state.successes == 0
      assert state.last_check_at == nil
      assert state.status == :healthy
      assert state.backoff_ms == :timer.minutes(30)
      assert state.last_error_class == nil
    end
  end

  describe "determine_status/3" do
    test "returns :unhealthy when failures reach threshold (3)" do
      assert Monitor.determine_status(3, 0, :healthy) == :unhealthy
      assert Monitor.determine_status(4, 0, :healthy) == :unhealthy
    end

    test "returns :degraded when failures are between 1 and 2" do
      assert Monitor.determine_status(1, 0, :healthy) == :degraded
      assert Monitor.determine_status(2, 0, :healthy) == :degraded
    end

    test "returns :healthy when a recovering integration reaches the threshold (2)" do
      assert Monitor.determine_status(0, 2, :unhealthy) == :healthy
      assert Monitor.determine_status(0, 2, :degraded) == :healthy
    end

    test "keeps a recovering integration below the threshold out of :healthy" do
      assert Monitor.determine_status(0, 0, :unhealthy) == :degraded
      assert Monitor.determine_status(0, 1, :unhealthy) == :degraded
      assert Monitor.determine_status(0, 1, :degraded) == :degraded
    end

    test "does not apply the threshold to an integration that has never failed" do
      assert Monitor.determine_status(0, 1, :healthy) == :healthy
    end
  end

  describe "update_health/2 with success" do
    test "resets failures and increments successes" do
      old_state = %{
        failures: 2,
        consecutive_hard_failures: 0,
        successes: 0,
        last_check_at: nil,
        status: :degraded,
        backoff_ms: :timer.minutes(5),
        last_error_class: :hard,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:ok, :result})

      assert new_state.failures == 0
      assert new_state.successes == 1
      assert new_state.status == :degraded
      assert new_state.backoff_ms == :timer.minutes(30)
      assert new_state.last_error_class == nil
      assert %DateTime{} = new_state.last_check_at
    end

    test "sets status to healthy after 2 consecutive successes" do
      old_state = %{
        failures: 0,
        consecutive_hard_failures: 0,
        successes: 1,
        last_check_at: DateTime.utc_now(),
        status: :degraded,
        backoff_ms: :timer.minutes(5),
        last_error_class: nil,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:ok, :result})

      assert new_state.successes == 2
      assert new_state.status == :healthy
    end
  end

  describe "recovery threshold" do
    test "a fresh integration is healthy from its first successful probe onwards" do
      state = Monitor.initial_state()
      after_first = Monitor.update_health(state, {:ok, :result})

      assert after_first.successes == 1
      assert after_first.status == :healthy

      after_second = Monitor.update_health(after_first, {:ok, :result})

      assert after_second.status == :healthy

      # The threshold used to apply here too, dropping a new integration to
      # :degraded and then reporting a recovery from a failure that never was.
      assert Monitor.detect_transition(after_first, after_second) ==
               {:no_change, :healthy, :healthy}
    end

    test "a failed integration still needs two consecutive successes to be healthy" do
      unhealthy =
        Enum.reduce(1..3, Monitor.initial_state(), fn _attempt, state ->
          Monitor.update_health(state, {:error, :boom, :hard})
        end)

      assert unhealthy.status == :unhealthy

      after_first = Monitor.update_health(unhealthy, {:ok, :result})

      assert after_first.successes == 1
      assert after_first.status == :degraded

      after_second = Monitor.update_health(after_first, {:ok, :result})

      assert after_second.successes == 2
      assert after_second.status == :healthy
    end
  end

  describe "update_health/2 with transient error" do
    test "does not increment failures" do
      old_state = Monitor.initial_state()

      new_state = Monitor.update_health(old_state, {:error, :timeout, :transient})

      assert new_state.failures == 0
      assert new_state.successes == 0
      assert new_state.status == :healthy
      assert new_state.last_error_class == :transient
      assert %DateTime{} = new_state.last_check_at
    end

    test "preserves existing status" do
      old_state = %{
        failures: 1,
        consecutive_hard_failures: 0,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: :degraded,
        backoff_ms: :timer.minutes(5),
        last_error_class: nil,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :rate_limited, :transient})

      assert new_state.status == :degraded
      assert new_state.failures == 1
    end
  end

  describe "update_health/2 with hard error" do
    test "increments failures and resets successes" do
      old_state = %{
        failures: 0,
        consecutive_hard_failures: 0,
        successes: 1,
        last_check_at: DateTime.utc_now(),
        status: :healthy,
        backoff_ms: :timer.minutes(5),
        last_error_class: nil,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :unauthorized, :hard})

      assert new_state.failures == 1
      assert new_state.successes == 0
      assert new_state.status == :degraded
      assert new_state.last_error_class == :hard
      assert %DateTime{} = new_state.last_check_at
    end

    test "sets status to unhealthy after 3 consecutive hard failures" do
      old_state = %{
        failures: 2,
        consecutive_hard_failures: 2,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: :degraded,
        backoff_ms: :timer.minutes(5),
        last_error_class: :hard,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :unauthorized, :hard})

      assert new_state.failures == 3
      assert new_state.status == :unhealthy
      assert %DateTime{} = new_state.became_unhealthy_at
    end

    test "preserves became_unhealthy_at on subsequent hard failures" do
      unhealthy_since = DateTime.add(DateTime.utc_now(), -49, :hour)

      old_state = %{
        failures: 3,
        consecutive_hard_failures: 3,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: :unhealthy,
        backoff_ms: :timer.hours(1),
        last_error_class: :hard,
        became_unhealthy_at: unhealthy_since,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :unauthorized, :hard})

      assert new_state.failures == 4
      assert new_state.became_unhealthy_at == unhealthy_since
    end

    test "schedules a 15-minute recovery probe on the first transition to unhealthy" do
      # Two prior hard failures, status still :degraded — the third hard failure
      # is the one that flips the status. The override should kick in here.
      old_state = %{
        failures: 2,
        consecutive_hard_failures: 2,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: :degraded,
        backoff_ms: :timer.hours(1),
        last_error_class: :hard,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :unauthorized, :hard})

      assert new_state.status == :unhealthy
      assert new_state.backoff_ms == :timer.minutes(15)
    end

    test "reverts to the standard 1-hour cadence on subsequent unhealthy probes" do
      # Already unhealthy — the override only fires on the *transition*.
      old_state = %{
        failures: 3,
        consecutive_hard_failures: 3,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: :unhealthy,
        backoff_ms: :timer.minutes(15),
        last_error_class: :hard,
        became_unhealthy_at: DateTime.utc_now(),
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :unauthorized, :hard})

      assert new_state.status == :unhealthy
      assert new_state.backoff_ms == :timer.hours(1)
    end
  end

  describe "update_health/2 with persistent transient errors (escalation)" do
    test "does not increment failures while backoff is below max" do
      old_state = %{
        failures: 0,
        consecutive_hard_failures: 0,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: :healthy,
        backoff_ms: :timer.minutes(5),
        last_error_class: :transient,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :econnrefused, :transient})

      assert new_state.failures == 0
      assert new_state.status == :healthy
    end

    test "starts incrementing failures when backoff reaches max" do
      old_state = %{
        failures: 0,
        consecutive_hard_failures: 0,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: :healthy,
        backoff_ms: :timer.hours(1),
        last_error_class: :transient,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :econnrefused, :transient})

      assert new_state.failures == 1
      assert new_state.status == :degraded
      assert new_state.last_error_class == :transient
    end

    test "reaches unhealthy after sustained transient failures at max backoff" do
      old_state = %{
        failures: 2,
        consecutive_hard_failures: 0,
        successes: 0,
        last_check_at: DateTime.utc_now(),
        status: :degraded,
        backoff_ms: :timer.hours(1),
        last_error_class: :transient,
        became_unhealthy_at: nil,
        notification_sent_at: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :econnrefused, :transient})

      assert new_state.failures == 3
      assert new_state.status == :unhealthy
      assert %DateTime{} = new_state.became_unhealthy_at
    end
  end
end
