defmodule Tymeslot.Integrations.HealthCheck.SchedulerTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Integrations.HealthCheck.Scheduler
  alias Tymeslot.Workers.IntegrationHealthWorker

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

  describe "schedule_all/1 with an undecryptable calendar integration" do
    test "still enqueues a health check for every active integration" do
      user = insert(:user)

      good = insert(:calendar_integration, user: user, provider: "caldav", is_active: true)

      # Undecryptable bytes stand in for a credential whose key is genuinely gone.
      stale =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          username_encrypted: :crypto.strong_rand_bytes(40),
          password_encrypted: :crypto.strong_rand_bytes(40)
        )

      assert :ok = Scheduler.schedule_all(force: true)

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => good.id}
      )

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => stale.id}
      )
    end
  end
end
