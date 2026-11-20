defmodule Tymeslot.Workers.SyncCalDavCalendarWorkerBreakerTest do
  @moduledoc """
  Two ways a CalDAV sync ends that are no operator's to fix, and so must not
  page one.

  An open host breaker refuses the cycle before any request is sent. Retrying
  it inside Oban's minute was refused twice more and then raised a
  permanent-failure alert, one per sync cycle while a self-hosted server was
  down. The worker snoozes past the breaker's recovery window instead, as the
  Google, Outlook and Exchange workers do.

  A redirect is never followed, so a server answering one (a provider in
  maintenance, or a base URL the owner's server has moved) is the owner's
  server configuration. The worker discards it, and the discard is declared
  an expected outcome.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.ProviderBreakers
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @base_url "http://localhost:65433"

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    with_config(:tymeslot, :sync_failure_unhealthy_threshold, 10)

    on_exit(&reset_breaker/0)

    integration =
      insert(:calendar_integration,
        provider: "caldav",
        base_url: @base_url,
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("s3cret"),
        calendar_paths: ["/calendars/alice/default/"],
        provider_account_id: "#{@base_url}||alice",
        is_active: true,
        needs_reauth: false,
        caldav_sync_tier: 3
      )

    %{integration: integration}
  end

  defp reset_breaker do
    CalendarCircuitBreaker.reset(:caldav, ProviderBreakers.host_from_base_url(@base_url))
    CalendarCircuitBreaker.reset(:caldav)
  end

  defp run_sync(integration),
    do: perform_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})

  defp breaker_status,
    do: CalendarCircuitBreaker.status(:caldav, ProviderBreakers.host_from_base_url(@base_url))

  # Drives the host's breaker open the way production did: syncs against a
  # server that never answers, until the breaker stops letting them through.
  defp open_breaker(integration) do
    ReqTest.stub(:tymeslot_http, fn conn -> ReqTest.transport_error(conn, :timeout) end)

    Enum.reduce_while(1..5, nil, fn _cycle, _acc ->
      run_sync(integration)
      if breaker_status().status == :open, do: {:halt, :open}, else: {:cont, nil}
    end)
  end

  defp health(integration), do: Monitor.get_state(:calendar, integration.id, integration.user_id)

  describe "perform/1 while the host's circuit breaker is open" do
    setup %{integration: integration} do
      assert open_breaker(integration) == :open
      :ok
    end

    test "snoozes past the breaker's recovery window instead of failing",
         %{integration: integration} do
      longest_recovery_s =
        div(ProviderBreakers.config(:calendar, :nextcloud).recovery_timeout, 1_000)

      # `{:error, :circuit_open}` here is what exhausted the job's attempts
      # inside a minute and raised an admin alert every cycle.
      assert {:snooze, seconds} = run_sync(integration)
      assert seconds > longest_recovery_s
    end

    test "sends nothing to the server", %{integration: integration} do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, :request_sent)
        ReqTest.transport_error(conn, :timeout)
      end)

      assert {:snooze, _seconds} = run_sync(integration)
      refute_received :request_sent
    end

    test "records nothing against the integration", %{integration: integration} do
      failures_before = health(integration).consecutive_sync_failures
      sync_error_before = Repo.reload!(integration).sync_error

      assert {:snooze, _seconds} = run_sync(integration)

      # The breaker is keyed by host: on a shared host it opens for every
      # account there, so counting its refusal would spread one account's
      # outage across everyone's badges.
      assert health(integration).consecutive_sync_failures == failures_before
      assert Repo.reload!(integration).sync_error == sync_error_before
    end
  end

  describe "perform/1 against a server answering with a redirect" do
    test "discards with an expected outcome", %{integration: integration} do
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("location", "https://elsewhere.example/dav/")
        |> Conn.send_resp(307, "")
      end)

      assert {:discard, reason} = run_sync(integration)
      assert reason =~ "HTTP 307"

      # Without this the discard still raised an admin alert, about a server
      # setting only its owner can change.
      assert SyncCalDavCalendarWorker.expected_outcome?(reason)
    end
  end
end
