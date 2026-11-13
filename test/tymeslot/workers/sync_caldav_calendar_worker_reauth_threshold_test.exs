defmodule Tymeslot.Workers.SyncCalDavCalendarWorkerReauthThresholdTest do
  @moduledoc """
  A credential rejection is believed only once it has lasted
  `ReauthHandling.password_rejection_threshold/0` consecutive sync cycles.
  A single 401 from a server that is briefly unable to authenticate anyone
  must not flag the integration, because a flagged integration is no longer
  synced and so can never clear the flag by itself. Only rejections count:
  a cycle that ends any other way starts the count again.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.CalDAVSyncTestFixtures
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    with_config(:tymeslot, :caldav_reauth_after_failed_cycles, 3)

    # Tier 3 is a plain full fetch, so one stubbed REPORT answer is a
    # complete successful cycle.
    integration =
      insert(:calendar_integration,
        provider: "caldav",
        base_url: "http://localhost:65432",
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("secret"),
        calendar_paths: [path1()],
        provider_account_id: "http://localhost:65432||alice",
        is_active: true,
        needs_reauth: false,
        caldav_sync_tier: 3
      )

    %{integration: integration}
  end

  defp reject_with(status),
    do: ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, status, "Unauthorized") end)

  defp fail_with_server_error,
    do: ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 503, "Unavailable") end)

  defp answer_successfully do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "application/xml")
      |> Conn.send_resp(207, caldav_report_xml("#{path1()}event1.ics", ical_path1()))
    end)
  end

  defp sync(integration),
    do: perform_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})

  defp reloaded(integration), do: Repo.get!(CalendarIntegrationSchema, integration.id)

  defp health_row(integration) do
    {:ok, row} = IntegrationHealthStateQueries.get(:calendar, integration.id)
    row
  end

  test "a single 401 discards the cycle without flagging and counts it", %{
    integration: integration
  } do
    reject_with(401)

    assert {:discard, reason} = sync(integration)
    assert SyncCalDavCalendarWorker.expected_outcome?(reason)

    refute reloaded(integration).needs_reauth
    assert reloaded(integration).sync_error == nil
    assert health_row(integration).consecutive_sync_failures == 1
    assert health_row(integration).consecutive_credential_rejections == 1
  end

  test "the rejection is believed on the cycle that reaches the threshold", %{
    integration: integration
  } do
    reject_with(401)

    assert {:discard, _reason} = sync(integration)
    assert {:discard, _reason} = sync(integration)
    refute reloaded(integration).needs_reauth

    assert {:discard, reason} = sync(integration)
    assert SyncCalDavCalendarWorker.expected_outcome?(reason)

    flagged = reloaded(integration)
    assert flagged.needs_reauth

    assert flagged.sync_error ==
             "CalDAV server rejected the stored credentials. Please reconnect the integration."
  end

  test "403 is held to the same threshold", %{integration: integration} do
    reject_with(403)

    assert {:discard, _reason} = sync(integration)
    assert {:discard, _reason} = sync(integration)
    refute reloaded(integration).needs_reauth

    assert {:discard, _reason} = sync(integration)
    assert reloaded(integration).needs_reauth
  end

  test "a successful cycle in between restarts the count", %{integration: integration} do
    reject_with(401)
    assert {:discard, _reason} = sync(integration)
    assert {:discard, _reason} = sync(integration)

    answer_successfully()
    assert :ok = sync(integration)
    assert health_row(integration).consecutive_credential_rejections == 0

    reject_with(401)
    assert {:discard, _reason} = sync(integration)
    assert {:discard, _reason} = sync(integration)
    refute reloaded(integration).needs_reauth
  end

  test "a cycle that fails another way in between restarts the count", %{
    integration: integration
  } do
    reject_with(401)
    assert {:discard, _reason} = sync(integration)
    assert {:discard, _reason} = sync(integration)

    fail_with_server_error()
    assert {:discard, _reason} = sync(integration)

    reject_with(401)
    assert {:discard, _reason} = sync(integration)
    assert {:discard, _reason} = sync(integration)
    refute reloaded(integration).needs_reauth
  end

  test "a long streak of other failures does not make a following 401 believed", %{
    integration: integration
  } do
    # Two cycles, so that with this one 401 the failed-sync streak alone would
    # reach the threshold. (More would open the host's circuit breaker.)
    fail_with_server_error()
    assert {:discard, _reason} = sync(integration)
    assert {:discard, _reason} = sync(integration)
    assert health_row(integration).consecutive_sync_failures == 2

    reject_with(401)
    assert {:discard, _reason} = sync(integration)
    refute reloaded(integration).needs_reauth
  end

  test "reconnecting the integration restarts the count", %{integration: integration} do
    reject_with(401)
    assert {:discard, _reason} = sync(integration)
    assert {:discard, _reason} = sync(integration)

    # What updating the credentials does.
    HealthCheck.mark_user_recovered(:calendar, integration.id)
    assert health_row(integration).consecutive_credential_rejections == 0

    assert {:discard, _reason} = sync(integration)
    refute reloaded(integration).needs_reauth
  end

  test "a threshold of 1 flags on the first rejection", %{integration: integration} do
    with_config(:tymeslot, :caldav_reauth_after_failed_cycles, 1)
    reject_with(401)

    assert {:discard, _reason} = sync(integration)
    assert reloaded(integration).needs_reauth
  end

  test "defaults to three cycles" do
    with_config(:tymeslot, :caldav_reauth_after_failed_cycles, nil)
    Application.delete_env(:tymeslot, :caldav_reauth_after_failed_cycles)

    assert ReauthHandling.password_rejection_threshold() == 3
  end
end
