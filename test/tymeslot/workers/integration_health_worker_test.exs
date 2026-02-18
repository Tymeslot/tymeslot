defmodule Tymeslot.Workers.IntegrationHealthWorkerTest do
  @moduletag :workers
  use Tymeslot.DataCase, async: false

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup :verify_on_exit!
  @moduletag :workers

  setup do
    {:ok, pid} = HealthCheck.start_link(check_interval: 1_000_000, initial_delay: 0)

    Mox.set_mox_global()

    on_exit(fn ->
      Mox.set_mox_private()

      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    {:ok, pid: pid}
  end

  test "discards invalid arguments" do
    job = %Oban.Job{args: %{"type" => "calendar"}}

    assert {:discard, "Invalid arguments"} = IntegrationHealthWorker.perform(job)
  end

  test "discards invalid integration type" do
    job = %Oban.Job{args: %{"type" => "unknown", "integration_id" => 1}}

    assert {:discard, "Invalid integration type"} = IntegrationHealthWorker.perform(job)
  end

  test "returns ok when health check reports transient error" do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

    expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
      {:error, :timeout}
    end)

    job = %Oban.Job{args: %{"type" => "calendar", "integration_id" => integration.id}, id: 1}

    assert :ok = IntegrationHealthWorker.perform(job)
    _state = :sys.get_state(HealthCheck, 5000)

    status = HealthCheck.get_health_status(:calendar, integration.id)
    assert status.status == :healthy
    assert status.failures == 0
    assert status.last_error_class == :transient
  end
end
