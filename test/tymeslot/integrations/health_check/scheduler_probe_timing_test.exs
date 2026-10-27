defmodule Tymeslot.Integrations.HealthCheck.SchedulerProbeTimingTest do
  @moduledoc """
  Whether the health sweep enqueues a probe, as a function of how long ago
  the integration was last checked: the due-rows query decides it, so a
  backoff boundary a second wide decides a real Oban job, and a sweep that
  runs every five minutes probes a healthy integration only once per
  interval.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Scheduler
  alias Tymeslot.Workers.{IntegrationHealthSweepWorker, IntegrationHealthWorker}

  # The backoff a freshly seeded health state carries.
  @default_backoff_ms 1_800_000

  setup do
    CalendarCircuitBreaker.reset(:google)
    now = ~U[2026-09-20 12:00:00Z]
    freeze_clock(now)

    user = insert(:user)
    integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

    {:ok, _state} =
      IntegrationHealthStateQueries.get_or_init(:calendar, integration.id, user.id)

    {:ok, now: now, integration: integration}
  end

  defp last_checked(integration, %DateTime{} = at) do
    {1, nil} =
      IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
        last_check_at: at,
        backoff_ms: @default_backoff_ms
      )

    :ok
  end

  test "enqueues a probe once the backoff has elapsed", %{now: now, integration: integration} do
    :ok = last_checked(integration, DateTime.add(now, -@default_backoff_ms, :millisecond))

    :ok = Scheduler.schedule_all()

    assert_enqueued(
      worker: IntegrationHealthWorker,
      args: %{"type" => "calendar", "integration_id" => integration.id}
    )
  end

  test "leaves it alone a second short of the backoff", %{now: now, integration: integration} do
    :ok = last_checked(integration, DateTime.add(now, -@default_backoff_ms + 1000, :millisecond))

    :ok = Scheduler.schedule_all()

    refute_enqueued(
      worker: IntegrationHealthWorker,
      args: %{"type" => "calendar", "integration_id" => integration.id}
    )
  end

  # Checks enqueued in one sweep are spread over the next thirty seconds,
  # never scheduled in the past.
  test "schedules each probe within the jitter window", %{now: now, integration: integration} do
    :ok = Scheduler.schedule_all()

    assert [%{scheduled_at: scheduled_at}] =
             all_enqueued(
               worker: IntegrationHealthWorker,
               args: %{"type" => "calendar", "integration_id" => integration.id}
             )

    assert DateTime.diff(scheduled_at, now, :millisecond) in 0..30_000
  end

  test "enqueues when the integration has never been checked", %{integration: integration} do
    :ok = Scheduler.schedule_all()

    assert_enqueued(
      worker: IntegrationHealthWorker,
      args: %{"type" => "calendar", "integration_id" => integration.id}
    )
  end

  # The sweep runs every five minutes; a healthy integration's interval is
  # thirty. Each probe that runs stamps `last_check_at`, as a real check does.
  test "a healthy integration is probed once per interval, not on every sweep", %{
    now: now,
    integration: integration
  } do
    probes =
      for minute <- 0..60//5, reduce: [] do
        probes ->
          at = DateTime.add(now, minute, :minute)
          freeze_clock(at)
          :ok = perform_job(IntegrationHealthSweepWorker, %{})

          if probe_enqueued?(integration) do
            :ok = last_checked(integration, at)
            discard_probes()
            [minute | probes]
          else
            probes
          end
      end

    assert Enum.reverse(probes) == [0, 30, 60]
  end

  test "a longer backoff is waited out in full", %{now: now, integration: integration} do
    {1, nil} =
      IntegrationHealthStateQueries.update_fields(:calendar, integration.id,
        last_check_at: DateTime.add(now, -45, :minute),
        backoff_ms: :timer.hours(1)
      )

    :ok = Scheduler.schedule_all()
    refute probe_enqueued?(integration)

    freeze_clock(DateTime.add(now, 15, :minute))
    :ok = Scheduler.schedule_all()
    assert probe_enqueued?(integration)
  end

  test "an integration with no health state is seeded once and probed" do
    user = insert(:user)
    fresh = insert(:calendar_integration, user: user, is_active: true, provider: "google")

    :ok = Scheduler.schedule_all()
    :ok = Scheduler.schedule_all()

    assert {:ok, %{last_check_at: nil, backoff_ms: @default_backoff_ms}} =
             IntegrationHealthStateQueries.get(:calendar, fresh.id)

    assert probe_enqueued?(fresh)
  end

  test "inactive and disconnected integrations are not probed" do
    user = insert(:user)
    paused = insert(:calendar_integration, user: user, is_active: false, provider: "google")
    disconnected = insert(:video_integration, user: user, deleted_at: DateTime.utc_now(:second))

    :ok = Scheduler.schedule_all()

    refute probe_enqueued?(paused)
    refute probe_enqueued?(disconnected, "video")
    assert {:error, :not_found} = IntegrationHealthStateQueries.get(:calendar, paused.id)
  end

  defp probe_enqueued?(integration, type \\ "calendar") do
    [worker: IntegrationHealthWorker, args: %{"type" => type, "integration_id" => integration.id}]
    |> all_enqueued()
    |> Enum.any?()
  end

  defp discard_probes do
    for job <- all_enqueued(worker: IntegrationHealthWorker), do: Repo.delete!(job)
  end
end
