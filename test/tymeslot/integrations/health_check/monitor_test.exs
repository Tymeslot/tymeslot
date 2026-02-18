defmodule Tymeslot.Integrations.HealthCheck.MonitorTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.HealthCheck.Monitor

  describe "initial_state/0" do
    test "returns a healthy initial state" do
      state = Monitor.initial_state()

      assert state.failures == 0
      assert state.successes == 0
      assert state.last_check == nil
      assert state.status == :healthy
      assert state.backoff_ms == :timer.minutes(5)
      assert state.last_error_class == nil
    end
  end

  describe "determine_status/2" do
    test "returns :unhealthy when failures reach threshold (3)" do
      assert Monitor.determine_status(3, 0) == :unhealthy
      assert Monitor.determine_status(4, 0) == :unhealthy
    end

    test "returns :degraded when failures are between 1 and 2" do
      assert Monitor.determine_status(1, 0) == :degraded
      assert Monitor.determine_status(2, 0) == :degraded
    end

    test "returns :healthy when successes reach recovery threshold (2)" do
      assert Monitor.determine_status(0, 2) == :healthy
      assert Monitor.determine_status(0, 3) == :healthy
    end

    test "returns :degraded when successes are below recovery threshold" do
      assert Monitor.determine_status(0, 0) == :degraded
      assert Monitor.determine_status(0, 1) == :degraded
    end
  end

  describe "update_health/2 with success" do
    test "resets failures and increments successes" do
      old_state = %{
        failures: 2,
        successes: 0,
        last_check: nil,
        status: :degraded,
        backoff_ms: :timer.minutes(5),
        last_error_class: :hard
      }

      new_state = Monitor.update_health(old_state, {:ok, :result})

      assert new_state.failures == 0
      assert new_state.successes == 1
      assert new_state.status == :degraded
      assert new_state.backoff_ms == :timer.minutes(5)
      assert new_state.last_error_class == nil
      assert %DateTime{} = new_state.last_check
    end

    test "sets status to healthy after 2 consecutive successes" do
      old_state = %{
        failures: 0,
        successes: 1,
        last_check: DateTime.utc_now(),
        status: :degraded,
        backoff_ms: :timer.minutes(5),
        last_error_class: nil
      }

      new_state = Monitor.update_health(old_state, {:ok, :result})

      assert new_state.successes == 2
      assert new_state.status == :healthy
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
      assert %DateTime{} = new_state.last_check
    end

    test "preserves existing status" do
      old_state = %{
        failures: 1,
        successes: 0,
        last_check: DateTime.utc_now(),
        status: :degraded,
        backoff_ms: :timer.minutes(5),
        last_error_class: nil
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
        successes: 1,
        last_check: DateTime.utc_now(),
        status: :healthy,
        backoff_ms: :timer.minutes(5),
        last_error_class: nil
      }

      new_state = Monitor.update_health(old_state, {:error, :unauthorized, :hard})

      assert new_state.failures == 1
      assert new_state.successes == 0
      assert new_state.status == :degraded
      assert new_state.last_error_class == :hard
      assert %DateTime{} = new_state.last_check
    end

    test "sets status to unhealthy after 3 consecutive hard failures" do
      old_state = %{
        failures: 2,
        successes: 0,
        last_check: DateTime.utc_now(),
        status: :degraded,
        backoff_ms: :timer.minutes(5),
        last_error_class: :hard
      }

      new_state = Monitor.update_health(old_state, {:error, :unauthorized, :hard})

      assert new_state.failures == 3
      assert new_state.status == :unhealthy
    end
  end

  describe "detect_transition/2" do
    test "detects initial failure" do
      old_state = %{Monitor.initial_state() | last_check: nil}
      new_state = %{old_state | status: :unhealthy, failures: 3}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:initial_failure, nil, :unhealthy}
    end

    test "detects no change for initial healthy check" do
      old_state = %{Monitor.initial_state() | last_check: nil}
      new_state = %{old_state | status: :healthy, last_check: DateTime.utc_now()}

      assert Monitor.detect_transition(old_state, new_state) == {:no_change, nil, :healthy}
    end

    test "detects transition to unhealthy from healthy" do
      old_state = %{
        Monitor.initial_state()
        | last_check: DateTime.utc_now(),
          status: :healthy
      }

      new_state = %{old_state | status: :unhealthy, failures: 3}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:became_unhealthy, :healthy, :unhealthy}
    end

    test "detects transition to unhealthy from degraded" do
      old_state = %{
        Monitor.initial_state()
        | last_check: DateTime.utc_now(),
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
        | last_check: DateTime.utc_now(),
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
        | last_check: DateTime.utc_now(),
          status: :healthy
      }

      new_state = %{old_state | status: :degraded, failures: 1}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:became_degraded, :healthy, :degraded}
    end

    test "detects no change for same status" do
      old_state = %{
        Monitor.initial_state()
        | last_check: DateTime.utc_now(),
          status: :healthy
      }

      new_state = %{old_state | successes: 3}

      assert Monitor.detect_transition(old_state, new_state) == {:no_change, :healthy, :healthy}
    end

    test "detects no change for degraded to degraded" do
      old_state = %{
        Monitor.initial_state()
        | last_check: DateTime.utc_now(),
          status: :degraded,
          failures: 1
      }

      new_state = %{old_state | failures: 2}

      assert Monitor.detect_transition(old_state, new_state) ==
               {:no_change, :degraded, :degraded}
    end
  end

  describe "get_state/3 and put_state/4" do
    test "get_state returns initial state for unknown integration" do
      state = %{calendar_health: %{}, video_health: %{}}

      health = Monitor.get_state(state, :calendar, 123)

      assert health == Monitor.initial_state()
    end

    test "get_state returns stored state for known calendar integration" do
      health_state = %{Monitor.initial_state() | failures: 2, status: :degraded}
      state = %{calendar_health: %{123 => health_state}, video_health: %{}}

      health = Monitor.get_state(state, :calendar, 123)

      assert health == health_state
    end

    test "get_state returns stored state for known video integration" do
      health_state = %{Monitor.initial_state() | failures: 1, status: :degraded}
      state = %{calendar_health: %{}, video_health: %{456 => health_state}}

      health = Monitor.get_state(state, :video, 456)

      assert health == health_state
    end

    test "put_state updates calendar integration state" do
      initial_state = %{calendar_health: %{}, video_health: %{}}
      health_state = %{Monitor.initial_state() | failures: 1}

      new_state = Monitor.put_state(initial_state, :calendar, 123, health_state)

      assert new_state.calendar_health[123] == health_state
      assert new_state.video_health == %{}
    end

    test "put_state updates video integration state" do
      initial_state = %{calendar_health: %{}, video_health: %{}}
      health_state = %{Monitor.initial_state() | failures: 2}

      new_state = Monitor.put_state(initial_state, :video, 456, health_state)

      assert new_state.video_health[456] == health_state
      assert new_state.calendar_health == %{}
    end
  end

  describe "build_user_report/2" do
    test "builds report for user with calendar and video integrations" do
      user = insert(:user)
      cal_int = insert(:calendar_integration, user: user, provider: "google", is_active: true)
      vid_int = insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

      cal_health = %{Monitor.initial_state() | failures: 1, status: :degraded}
      vid_health = %{Monitor.initial_state() | failures: 3, status: :unhealthy}

      state = %{
        calendar_health: %{cal_int.id => cal_health},
        video_health: %{vid_int.id => vid_health}
      }

      report = Monitor.build_user_report(user.id, state)

      assert length(report.calendar_integrations) == 1
      assert length(report.video_integrations) == 1

      cal_report = Enum.find(report.calendar_integrations, &(&1.id == cal_int.id))
      assert cal_report.provider == "google"
      assert cal_report.is_active == true
      assert cal_report.health == cal_health

      vid_report = Enum.find(report.video_integrations, &(&1.id == vid_int.id))
      assert vid_report.provider == "mirotalk"
      assert vid_report.is_active == true
      assert vid_report.health == vid_health

      assert report.summary.healthy_count == 0
      assert report.summary.degraded_count == 1
      assert report.summary.unhealthy_count == 1
    end

    test "uses initial state for integrations without tracked health" do
      user = insert(:user)
      cal_int = insert(:calendar_integration, user: user, provider: "google", is_active: true)

      state = %{calendar_health: %{}, video_health: %{}}

      report = Monitor.build_user_report(user.id, state)

      cal_report = Enum.find(report.calendar_integrations, &(&1.id == cal_int.id))
      assert cal_report.health == Monitor.initial_state()
    end

    test "returns empty report for user with no integrations" do
      user = insert(:user)
      state = %{calendar_health: %{}, video_health: %{}}

      report = Monitor.build_user_report(user.id, state)

      assert report.calendar_integrations == []
      assert report.video_integrations == []
      assert report.summary.healthy_count == 0
      assert report.summary.degraded_count == 0
      assert report.summary.unhealthy_count == 0
    end
  end
end
