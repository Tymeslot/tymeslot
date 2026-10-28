defmodule Tymeslot.Integrations.HealthCheck.SchedulerTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.HealthCheck.Scheduler
  alias Tymeslot.Workers.IntegrationHealthWorker

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

  # A leaving owner may already have revoked what Tymeslot holds; probing it
  # would flag the integration and email them about an account they are
  # leaving. A restore puts the integrations back on the next sweep.
  describe "schedule_all/1 with an account pending deletion" do
    test "checks no integration of that account until it is restored" do
      leaving =
        insert(:user, deletion_scheduled_at: DateTime.add(DateTime.utc_now(:second), 86_400))

      calendar = insert(:calendar_integration, user: leaving, provider: "caldav", is_active: true)
      video = insert(:video_integration, user: leaving, is_active: true)
      staying = insert(:calendar_integration, provider: "caldav", is_active: true)

      assert :ok = Scheduler.schedule_all(force: true)

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => staying.id}
      )

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => calendar.id}
      )

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "video", "integration_id" => video.id}
      )

      Repo.update!(Changeset.change(leaving, deletion_scheduled_at: nil))
      assert :ok = Scheduler.schedule_all(force: true)

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => calendar.id}
      )
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
