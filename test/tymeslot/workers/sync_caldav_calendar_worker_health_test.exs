defmodule Tymeslot.Workers.SyncCalDavCalendarWorkerHealthTest do
  @moduledoc """
  A CalDAV server that 5xxs every sync must eventually surface as an unhealthy
  integration.

  The worker discards a `:server_error` rather than retrying to exhaustion, and
  `ObanFailureAlerter` deliberately ignores an intentional discard, so before
  this behaviour existed a remote could fail every sync for weeks with a green
  badge and no alert. These tests drive the real worker against a server that
  answers 500 and assert the streak reaches the badge.
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
  alias Tymeslot.Integrations.HealthCheck.Monitor
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
        # Tier 3 so a failing cycle is exactly one refused request. On tier 1 a
        # refusal also demotes (see `CalDAV.TierDemotionTest`), and against a
        # server that refuses everything the extra requests trip the calendar
        # circuit breaker, which is correct but is not what these tests are
        # about.
        caldav_sync_tier: 3
      )

    %{integration: integration}
  end

  defp run_failing_sync(integration) do
    ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 500, "Internal Server Error") end)

    assert {:discard, _reason} =
             perform_job(SyncCalDavCalendarWorker, %{
               "calendar_integration_id" => integration.id
             })
  end

  defp health(integration), do: Monitor.get_state(:calendar, integration.id, integration.user_id)

  describe "perform/1 against a CalDAV server that returns 500" do
    test "counts each discarded cycle against the integration's health",
         %{integration: integration} do
      assert health(integration).consecutive_sync_failures == 0

      run_failing_sync(integration)
      assert health(integration).consecutive_sync_failures == 1

      run_failing_sync(integration)
      assert health(integration).consecutive_sync_failures == 2
    end

    test "marks the integration unhealthy once the streak reaches the threshold",
         %{integration: integration} do
      for _cycle <- 1..2, do: run_failing_sync(integration)

      # Below the threshold the badge stays clear: a couple of failed cycles is
      # the transient blip the discard-quietly design exists to absorb.
      assert health(integration).status == :healthy
      assert is_nil(health(integration).became_unhealthy_at)

      run_failing_sync(integration)

      state = health(integration)
      assert state.consecutive_sync_failures == 3
      assert state.status == :unhealthy
      assert %DateTime{} = state.became_unhealthy_at
    end

    test "leaves consecutive_hard_failures alone so SyncGating does not pause the integration",
         %{integration: integration} do
      for _cycle <- 1..3, do: run_failing_sync(integration)

      state = health(integration)
      assert state.status == :unhealthy

      # A remote 5xx is precisely the case where pausing sync would stop the
      # integration ever discovering the server had recovered.
      assert state.consecutive_hard_failures == 0
      assert state.failures == 0
    end
  end
end
