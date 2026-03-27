defmodule Tymeslot.Integrations.HealthCheck.MonitorTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.DatabaseQueries.IntegrationHealthStateQueries
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
  end

  describe "update_health/2 with persistent transient errors (escalation)" do
    test "does not increment failures while backoff is below max" do
      old_state = %{
        failures: 0,
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

  describe "get_state/3 and put_state/3" do
    test "get_state creates a default healthy record for unknown integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      health = Monitor.get_state(:calendar, integration.id, user.id)

      assert health.status == :healthy
      assert health.failures == 0
      assert health.successes == 0
      assert health.last_check_at == nil
    end

    test "get_state returns existing state from DB" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          status: "degraded",
          failures: 2,
          successes: 0,
          backoff_ms: :timer.minutes(5),
          last_check_at: DateTime.utc_now()
        )

      health = Monitor.get_state(:calendar, integration.id, user.id)

      assert health.status == :degraded
      assert health.failures == 2
    end

    test "put_state persists health state to DB" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      health_state = %{
        Monitor.initial_state()
        | failures: 1,
          status: :degraded,
          last_check_at: DateTime.utc_now()
      }

      assert {1, _nil} = Monitor.put_state(:calendar, integration.id, health_state)

      {:ok, record} = IntegrationHealthStateQueries.get(:calendar, integration.id)
      assert record.status == "degraded"
      assert record.failures == 1
    end

    test "put_state returns {0, nil} when no record exists" do
      health_state = %{
        Monitor.initial_state()
        | failures: 1,
          status: :degraded,
          last_check_at: DateTime.utc_now()
      }

      assert {0, nil} = Monitor.put_state(:calendar, -1, health_state)
    end

    test "put_state persists video integration state to DB" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:video, integration.id, user.id)

      health_state = %{Monitor.initial_state() | failures: 2, status: :degraded}

      assert {1, _nil} = Monitor.put_state(:video, integration.id, health_state)

      {:ok, record} = IntegrationHealthStateQueries.get(:video, integration.id)
      assert record.status == "degraded"
      assert record.failures == 2
    end
  end

  describe "from_db_record/1" do
    test "handles unexpected status string without crashing" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          status: "some_future_status"
        )

      health = Monitor.get_state(:calendar, integration.id, user.id)
      assert health.status == :degraded
    end

    test "handles unexpected last_error_class string without crashing" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      {:ok, _record} =
        IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
          last_error_class: "unknown_class"
        )

      health = Monitor.get_state(:calendar, integration.id, user.id)
      assert health.last_error_class == :hard
    end
  end

  describe "orphaned health state cleanup" do
    test "delete_orphaned removes health states for deleted integrations" do
      user = insert(:user)
      cal = insert(:calendar_integration, user: user)
      vid = insert(:video_integration, user: user)

      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:calendar, cal.id, user.id)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:video, vid.id, user.id)

      # Create orphaned records (integration IDs that don't exist)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:calendar, -999, user.id)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:video, -998, user.id)

      {deleted, _nil} = IntegrationHealthStateQueries.delete_orphaned()

      assert deleted == 2

      # Real records still exist
      assert {:ok, _record} = IntegrationHealthStateQueries.get(:calendar, cal.id)
      assert {:ok, _record} = IntegrationHealthStateQueries.get(:video, vid.id)

      # Orphaned records are gone
      assert {:error, :not_found} = IntegrationHealthStateQueries.get(:calendar, -999)
      assert {:error, :not_found} = IntegrationHealthStateQueries.get(:video, -998)
    end

    test "delete_orphaned returns {0, nil} when no orphans exist" do
      user = insert(:user)
      cal = insert(:calendar_integration, user: user)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:calendar, cal.id, user.id)

      assert {0, _nil} = IntegrationHealthStateQueries.delete_orphaned()
    end
  end

  describe "build_user_report/1" do
    test "builds report for user with calendar and video integrations" do
      user = insert(:user)
      cal_int = insert(:calendar_integration, user: user, provider: "google", is_active: true)
      vid_int = insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:calendar, cal_int.id, user.id)
      {:ok, _record} = IntegrationHealthStateQueries.get_or_init(:video, vid_int.id, user.id)

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:calendar, cal_int.id,
          status: "degraded",
          failures: 1,
          successes: 0,
          backoff_ms: :timer.minutes(5),
          last_check_at: DateTime.utc_now()
        )

      {1, _nil} =
        IntegrationHealthStateQueries.update_fields(:video, vid_int.id,
          status: "unhealthy",
          failures: 3,
          successes: 0,
          backoff_ms: :timer.hours(1),
          last_check_at: DateTime.utc_now()
        )

      report = Monitor.build_user_report(user.id)

      assert length(report.calendar_integrations) == 1
      assert length(report.video_integrations) == 1

      cal_report = Enum.find(report.calendar_integrations, &(&1.id == cal_int.id))
      assert cal_report.provider == "google"
      assert cal_report.is_active == true
      assert cal_report.health.status == :degraded

      vid_report = Enum.find(report.video_integrations, &(&1.id == vid_int.id))
      assert vid_report.provider == "mirotalk"
      assert vid_report.is_active == true
      assert vid_report.health.status == :unhealthy

      assert report.summary.healthy_count == 0
      assert report.summary.degraded_count == 1
      assert report.summary.unhealthy_count == 1
    end

    test "uses initial state for integrations without tracked health" do
      user = insert(:user)
      cal_int = insert(:calendar_integration, user: user, provider: "google", is_active: true)

      report = Monitor.build_user_report(user.id)

      cal_report = Enum.find(report.calendar_integrations, &(&1.id == cal_int.id))
      assert cal_report.health.status == :healthy
      assert cal_report.health.failures == 0
    end

    test "returns empty report for user with no integrations" do
      user = insert(:user)

      report = Monitor.build_user_report(user.id)

      assert report.calendar_integrations == []
      assert report.video_integrations == []
      assert report.summary.healthy_count == 0
      assert report.summary.degraded_count == 0
      assert report.summary.unhealthy_count == 0
    end
  end
end
