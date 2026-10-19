defmodule Tymeslot.Integrations.HealthCheck.SchedulerCircuitBreakerTest do
  # Host breakers are dynamically registered, global processes shared with
  # every other test, and DataCase resets them in its setup; async: false
  # keeps a concurrently running module from resetting the one tripped here.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.HealthCheck.Scheduler
  alias Tymeslot.Workers.IntegrationHealthWorker

  @moduletag :integrations
  @moduletag :capture_log

  describe "schedule_all/1 with a self-hosted calendar whose server is down" do
    test "skips the integrations on that server and checks the rest" do
      user = insert(:user)

      down =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          base_url: "https://dav.down.example/remote.php/dav"
        )

      up =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          base_url: "https://dav.up.example/remote.php/dav"
        )

      # A generic CalDAV client on a `/remote.php/dav` URL is a Nextcloud
      # client, so its calls trip the host's `:nextcloud` breaker.
      trip_host_breaker(:nextcloud, "dav.down.example")

      assert :ok = Scheduler.schedule_all(force: true)

      refute_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => down.id}
      )

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => up.id}
      )
    end
  end

  describe "schedule_all/1 with a self-hosted calendar whose server has had no traffic yet" do
    # Host breakers start on a server's first call and are reaped once idle,
    # so after a boot (or a quiet day) there is none for a healthy server.
    # The module captures logs; capture this test's own to see an error.
    test "checks it as a closed breaker, without logging an error" do
      host = "dav-fresh-#{System.unique_integer([:positive])}.example"

      fresh =
        insert(:calendar_integration,
          user: insert(:user),
          provider: "caldav",
          is_active: true,
          base_url: "https://#{host}/remote.php/dav"
        )

      assert {:error, :breaker_not_found} = CalendarCircuitBreaker.status(:nextcloud, host)

      log = capture_log([level: :error], fn -> Scheduler.schedule_all(force: true) end)

      assert_enqueued(
        worker: IntegrationHealthWorker,
        args: %{"type" => "calendar", "integration_id" => fresh.id}
      )

      refute log =~ "Circuit breaker not initialized"
    end
  end

  describe "CalendarCircuitBreaker host breakers" do
    test "reset/2 closes the breaker a server's calls tripped" do
      host = "reset-#{System.unique_integer([:positive])}.example.com"
      trip_host_breaker(:caldav, host)

      assert :ok = CalendarCircuitBreaker.reset(:caldav, host)
      assert %{status: :closed} = CalendarCircuitBreaker.status(:caldav, host)
    end
  end

  # Fails calls through the same host breaker CalDAV traffic uses until it
  # opens. `status/2` is a call to the breaker process, queued behind the
  # outcome casts, so its answer reflects every failure recorded here.
  defp trip_host_breaker(provider, host) do
    threshold = CalendarCircuitBreaker.get_config(provider).failure_threshold

    for _attempt <- 1..threshold do
      CalendarCircuitBreaker.with_breaker(provider, [host: host], fn ->
        {:provider_error, :unreachable}
      end)
    end

    assert %{status: :open} = CalendarCircuitBreaker.status(provider, host)
  end
end
