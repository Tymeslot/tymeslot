defmodule Tymeslot.Integrations.HealthCheckTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory
  import Tymeslot.Integrations.HealthCheckTestSetup
  import Ecto.Query
  import Mox

  alias Oban.Job
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.ResponseHandler
  alias Tymeslot.Repo
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!
  setup :start_health_check_server

  describe "integration health monitoring" do
    test "marks integration as unhealthy after repeated failures" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Mock failure for 3 checks (threshold is 3)
      expect(GoogleCalendarAPIMock, :list_primary_events, 3, fn _integration,
                                                                _start_date,
                                                                _end_date ->
        {:error, :unauthorized, "Token expired"}
      end)

      # 1st failure
      run_health_checks()
      sync_with_server()
      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :degraded
      assert status.failures == 1

      # 2nd failure
      run_health_checks()
      sync_with_server()
      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :degraded
      assert status.failures == 2

      # 3rd failure
      run_health_checks()
      sync_with_server()
      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :unhealthy
      assert status.failures == 3

      # Verify integration remains active in DB (no auto-deactivation)
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.is_active == true
    end

    test "recovers integration after repeated successes" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Initial failure to make it degraded — return the 3-tuple shape that
      # `Google.Provider.test_connection/1` translates into `{:error, :unauthorized}`,
      # which is unambiguously a :hard failure.
      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _integration,
                                                                _start_date,
                                                                _end_date ->
        {:error, :unauthorized, "Token revoked"}
      end)

      run_health_checks()
      sync_with_server()
      assert HealthCheck.get_health_status(:calendar, integration.id).status == :degraded

      # Mock success for 2 checks (recovery threshold is 2)
      expect(GoogleCalendarAPIMock, :list_primary_events, 2, fn _integration,
                                                                _start_date,
                                                                _end_date ->
        {:ok, []}
      end)

      # 1st success
      run_health_checks()
      sync_with_server()
      assert HealthCheck.get_health_status(:calendar, integration.id).status == :degraded

      # 2nd success
      run_health_checks()
      sync_with_server()
      assert HealthCheck.get_health_status(:calendar, integration.id).status == :healthy
    end

    test "treats timeout as transient and keeps healthy status" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Mock a slow response
      # Note: Oban doesn't have a built-in "timeout" return value like Task.yield,
      # but the underlying integration call might timeout.
      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _integration,
                                                                _start_date,
                                                                _end_date ->
        {:error, :timeout}
      end)

      # Trigger check
      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "treats timeout exception as transient" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        raise "Timeout while contacting provider"
      end)

      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "handles integration check crash" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      # Mock a crash
      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        raise "Unexpected crash"
      end)

      # Trigger check
      run_health_checks()
      sync_with_server()

      # Crashes are wrapped as `{:error, {:exception, message}}` and treated
      # as `:transient` under the conservative classification policy. The
      # important property is that a single crash does not immediately push
      # the integration toward `:unhealthy`.
      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "treats http 429 as transient" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:http_error, 429, "Too Many Requests"}
      end)

      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "treats rate limited message as transient" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, :rate_limited, "Rate limited"}
      end)

      run_health_checks()
      sync_with_server()

      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end

    test "handles non-utf8 error messages without crashing" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, <<255>>}
      end)

      run_health_checks()
      sync_with_server()

      # Non-UTF-8 garbage from a provider is opaque — under the conservative
      # classification policy we default unknown errors to `:transient` rather
      # than `:hard`. The system must remain stable and not increment failure
      # counters on input it cannot meaningfully classify.
      status = HealthCheck.get_health_status(:calendar, integration.id)
      assert status.status == :healthy
      assert status.failures == 0
      assert status.last_error_class == :transient
    end
  end

  describe "attention_status/2" do
    test "paused wins even when needs_reauth is also true and health is unhealthy" do
      assert HealthCheck.attention_status(
               %{is_active: false, needs_reauth: true},
               %{status: :unhealthy}
             ) == :paused
    end

    test "paused wins over a plain needs_reauth integration" do
      assert HealthCheck.attention_status(%{is_active: false, needs_reauth: true}, nil) ==
               :paused
    end

    test "paused wins for an active-flag-false integration with no other issues" do
      assert HealthCheck.attention_status(%{is_active: false, needs_reauth: false}, nil) ==
               :paused
    end

    test "needs_reauth wins over unhealthy health when active" do
      assert HealthCheck.attention_status(
               %{is_active: true, needs_reauth: true},
               %{status: :unhealthy}
             ) == :needs_reauth
    end

    test "needs_reauth wins with nil health when active" do
      assert HealthCheck.attention_status(%{is_active: true, needs_reauth: true}, nil) ==
               :needs_reauth
    end

    test "unhealthy health on an active, non-reauth integration" do
      assert HealthCheck.attention_status(
               %{is_active: true, needs_reauth: false},
               %{status: :unhealthy}
             ) == :unhealthy
    end

    test "ok for an active, non-reauth integration with nil health" do
      assert HealthCheck.attention_status(%{is_active: true, needs_reauth: false}, nil) == :ok
    end

    test "ok for an active, non-reauth integration with healthy health" do
      assert HealthCheck.attention_status(
               %{is_active: true, needs_reauth: false},
               %{status: :healthy}
             ) == :ok
    end
  end

  describe "user health report" do
    test "builds correct report for user" do
      user = insert(:user)
      c1 = insert(:calendar_integration, user: user, provider: "google")
      v1 = insert(:video_integration, user: user, provider: "mirotalk")

      # Mock success for both, across two probe rounds: `@recovery_threshold`
      # is 2, so a single success leaves an integration :degraded and the
      # summary would say nothing about the success path working.
      expect(GoogleCalendarAPIMock, :list_primary_events, 2, fn _int, _start, _end ->
        {:ok, []}
      end)

      # One POST per MiroTalk probe, so two across the two rounds. The count is
      # load-bearing: it once stood at four, because `validate_config/1` ran a
      # full `test_connection/1` of its own before `ProviderRegistry` ran the
      # real one, doubling the traffic this probe sends to the customer's
      # self-hosted server.
      expect(Tymeslot.HTTPClientMock, :post, 2, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200}}
      end)

      run_health_checks()
      sync_with_server()
      run_health_checks()
      sync_with_server()

      report = HealthCheck.get_user_health_report(user.id)

      assert [%{id: calendar_id, provider: "google", health: %{status: :healthy, successes: 2}}] =
               report.calendar_integrations

      assert calendar_id == c1.id

      assert [%{id: video_id, provider: "mirotalk", health: %{status: :healthy, successes: 2}}] =
               report.video_integrations

      assert video_id == v1.id

      assert report.summary == %{healthy_count: 2, degraded_count: 0, unhealthy_count: 0}
    end
  end

  describe "permanent auth failure fast path" do
    @moduletag :integration

    test "calendar invalid_grant flags needs_reauth and enqueues email immediately" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, :unauthorized, "Token has been expired or revoked"}
      end)

      run_health_checks()
      sync_with_server()

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == true
      assert updated.is_active == true

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "calendar"
        }
      )
    end

    test "transient errors do not trigger fast path" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, 1, fn _int, _start, _end ->
        {:error, :timeout}
      end)

      run_health_checks()
      sync_with_server()

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == false
      refute_enqueued(worker: EmailWorker)
    end

    # The health-check pipeline calls the calendar API mock directly, bypassing
    # the token-refresh HTTP path. We exercise the full wiring from raw HTTP body
    # → GoogleOAuthHelper → ResponseHandler in two explicit steps rather than
    # routing through run_health_checks/0, which cannot reach TokenExchange.
    test "invalid_grant HTTP 400 body wires through refresh helper to needs_reauth flag and email" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true,
          needs_reauth: false
        )

      Application.put_env(:tymeslot, :google_oauth,
        client_id: "test-client-id",
        client_secret: "test-client-secret",
        state_secret: "test-state-secret"
      )

      on_exit(fn -> Application.delete_env(:tymeslot, :google_oauth) end)

      # Step 1: HTTP layer returns 400 + invalid_grant body.
      # Verify GoogleOAuthHelper surfaces this as a string reason that carries
      # the OAuth error code — which is what ResponseHandler pattern-matches on.
      expect(Tymeslot.HTTPClientMock, :request, 1, fn :post,
                                                      "https://oauth2.googleapis.com/token",
                                                      _body,
                                                      _headers,
                                                      _opts ->
        {:ok, %{status: 400, body: ~s({"error":"invalid_grant"})}}
      end)

      assert {:error, reason} = GoogleOAuthHelper.refresh_access_token("stale-refresh-token")
      assert reason == "Token refresh failed: invalid_grant"

      # Step 2: Feed the propagated reason into the response handler and confirm
      # the integration is flagged for reauth and the notification is enqueued.
      ResponseHandler.handle_permanent_auth_failure(:calendar, integration, {:error, reason})

      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.needs_reauth == true

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "calendar"
        }
      )
    end
  end

  describe "deactivated integration handling" do
    test "skips health check for deactivated calendar integration" do
      user = insert(:user)

      integration =
        insert(:calendar_integration, user: user, is_active: false, provider: "google")

      result = HealthCheck.perform_single_check(:calendar, integration.id)

      assert result == :ok
    end

    test "skips health check for deactivated video integration" do
      user = insert(:user)
      integration = insert(:video_integration, user: user, is_active: false, provider: "mirotalk")

      result = HealthCheck.perform_single_check(:video, integration.id)

      assert result == :ok
    end
  end

  describe "deleted integration handling" do
    test "returns :ok for non-existent calendar integration" do
      result = HealthCheck.perform_single_check(:calendar, -1)
      assert result == :ok
    end

    test "returns :ok for non-existent video integration" do
      result = HealthCheck.perform_single_check(:video, -1)
      assert result == :ok
    end
  end

  defp run_health_checks do
    Repo.delete_all(from(j in Job, where: j.queue == "calendar_integrations"))

    HealthCheck.check_all_integrations()
    now = DateTime.utc_now()

    Repo.update_all(
      from(j in Job, where: j.queue == "calendar_integrations" and j.state == "scheduled"),
      set: [scheduled_at: now, state: "available"]
    )

    Oban.drain_queue(queue: :calendar_integrations, with_limit: 100)
  end
end
