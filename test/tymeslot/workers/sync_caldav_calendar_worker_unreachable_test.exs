defmodule Tymeslot.Workers.SyncCalDavCalendarWorkerUnreachableTest do
  @moduledoc """
  A CalDAV server that never answers must not page an operator once per sync
  cycle.

  A timeout is the remote's condition, like the 5xx the worker already
  discards, and the three Oban attempts that follow it span under a minute —
  far too short for a host that is down to come back. Before this, an hour of
  downtime produced a permanent-failure admin alert per cycle about an outage
  no operator here could act on. These tests drive the real worker against a
  server that never responds and assert it discards instead, while the failure
  still reaches the integration's health badge.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers

  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    with_config(:tymeslot, :sync_failure_unhealthy_threshold, 3)

    integration =
      insert(:calendar_integration,
        provider: "caldav",
        base_url: "http://localhost:65432",
        username_encrypted: Encryption.encrypt("alice"),
        password_encrypted: Encryption.encrypt("s3cret"),
        calendar_paths: ["/calendars/alice/default/"],
        provider_account_id: "http://localhost:65432||alice",
        is_active: true,
        needs_reauth: false,
        # Tier 3, so one failing cycle is one refused request — the same
        # reasoning as the 5xx health test next door.
        caldav_sync_tier: 3
      )

    %{integration: integration}
  end

  defp run_unreachable_sync(integration) do
    ReqTest.stub(:tymeslot_http, fn conn -> ReqTest.transport_error(conn, :timeout) end)

    perform_job(SyncCalDavCalendarWorker, %{"calendar_integration_id" => integration.id})
  end

  defp health(integration), do: Monitor.get_state(:calendar, integration.id, integration.user_id)

  describe "perform/1 against a CalDAV server that never answers" do
    test "discards rather than exhausting its retries", %{integration: integration} do
      # `{:error, _}` here is what raised an admin alert every cycle: Oban
      # retries twice more within the minute, then reports the job as failed
      # permanently.
      assert {:discard, reason} = run_unreachable_sync(integration)
      assert reason =~ "did not respond"
    end

    test "still counts the cycle against the integration's health",
         %{integration: integration} do
      assert health(integration).consecutive_sync_failures == 0

      run_unreachable_sync(integration)

      # The discard is what keeps the alerts quiet, so the streak is the only
      # thing left that can surface a server which never comes back.
      assert health(integration).consecutive_sync_failures == 1
    end

    test "leaves the integration connected and active", %{integration: integration} do
      run_unreachable_sync(integration)

      reloaded = Repo.reload!(integration)

      # Nothing about the credentials was learnt: a server that does not answer
      # has not rejected them.
      refute reloaded.needs_reauth
      assert reloaded.is_active
    end
  end
end
