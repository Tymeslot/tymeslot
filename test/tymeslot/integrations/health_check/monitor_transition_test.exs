defmodule Tymeslot.Integrations.HealthCheck.MonitorTransitionTest do
  @moduledoc """
  Covers `Monitor.detect_transition/2` — how a pair of consecutive health
  states is classified into the event that drives user notifications.

  The state machine that produces those states lives in
  `MonitorHealthStateTest`.
  """
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.HealthCheck.Monitor

  describe "detect_transition/2" do
    test "detects initial failure" do
      old_state = %{Monitor.initial_state() | last_check_at: nil}
      new_state = %{old_state | status: :unhealthy, failures: 3}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:initial_failure, nil, :unhealthy}
    end

    test "detects no change for initial healthy check" do
      old_state = %{Monitor.initial_state() | last_check_at: nil}
      new_state = %{old_state | status: :healthy, last_check_at: DateTime.utc_now()}

      assert Monitor.detect_transition(old_state, new_state) == {:no_change, nil, :healthy}
    end

    test "detects transition to unhealthy from healthy" do
      old_state = %{
        Monitor.initial_state()
        | last_check_at: DateTime.utc_now(),
          status: :healthy
      }

      new_state = %{old_state | status: :unhealthy, failures: 3}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:became_unhealthy, :healthy, :unhealthy}
    end

    test "detects transition to unhealthy from degraded" do
      old_state = %{
        Monitor.initial_state()
        | last_check_at: DateTime.utc_now(),
          status: :degraded,
          failures: 2
      }

      new_state = %{old_state | status: :unhealthy, failures: 3}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:became_unhealthy, :degraded, :unhealthy}
    end

    test "detects recovery from unhealthy to healthy" do
      old_state = %{
        Monitor.initial_state()
        | last_check_at: DateTime.utc_now(),
          status: :unhealthy,
          failures: 3
      }

      new_state = %{old_state | status: :healthy, failures: 0, successes: 2}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:became_healthy, :unhealthy, :healthy}
    end

    test "detects degradation from healthy to degraded" do
      old_state = %{
        Monitor.initial_state()
        | last_check_at: DateTime.utc_now(),
          status: :healthy
      }

      new_state = %{old_state | status: :degraded, failures: 1}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:became_degraded, :healthy, :degraded}
    end

    test "detects no change for same status" do
      old_state = %{
        Monitor.initial_state()
        | last_check_at: DateTime.utc_now(),
          status: :healthy
      }

      new_state = %{old_state | successes: 3}

      assert Monitor.detect_transition(old_state, new_state) == {:no_change, :healthy, :healthy}
    end

    test "detects no change for degraded to degraded" do
      old_state = %{
        Monitor.initial_state()
        | last_check_at: DateTime.utc_now(),
          status: :degraded,
          failures: 1
      }

      new_state = %{old_state | failures: 2}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:no_change, :degraded, :degraded}
    end
  end
end
