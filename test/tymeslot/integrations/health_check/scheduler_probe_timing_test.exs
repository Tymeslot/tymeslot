defmodule Tymeslot.Integrations.HealthCheck.SchedulerProbeTimingTest do
  @moduledoc """
  Whether `Scheduler.schedule_all/1` actually enqueues a probe, as a function
  of how long ago the integration was last checked. `due_for_check?/2` takes
  `now` as an argument and is covered directly; what is only observable here
  is that the sweep reads the clock and passes the same instant down, so a
  backoff boundary a second wide decides a real Oban job.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Scheduler
  alias Tymeslot.Workers.IntegrationHealthWorker

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

  test "enqueues when the integration has never been checked", %{integration: integration} do
    :ok = Scheduler.schedule_all()

    assert_enqueued(
      worker: IntegrationHealthWorker,
      args: %{"type" => "calendar", "integration_id" => integration.id}
    )
  end
end
