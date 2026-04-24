defmodule Tymeslot.Workers.SyncCalDavCalendarWorkerReauthTest do
  @moduledoc """
  A sync worker that encounters a credential it cannot decrypt must flag the
  integration as `needs_reauth` and complete the Oban job with `{:discard, _}`
  — never crash. Once the user reconnects, the flag must clear so the
  sweep-level `needs_reauth` filter doesn't keep the integration stranded.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar
  @moduletag :security
  @moduletag :integrations

  use Oban.Testing, repo: Tymeslot.Repo

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @endpoint TymeslotWeb.Endpoint
  @key_a String.duplicate("a", 64)
  @key_b String.duplicate("b", 64)

  setup do
    original = Application.get_env(:tymeslot, @endpoint)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, @endpoint)
      else
        Application.put_env(:tymeslot, @endpoint, original)
      end
    end)

    :ok
  end

  defp put_secret_key(key) do
    base = Application.get_env(:tymeslot, @endpoint) || []

    base
    |> Keyword.put(:secret_key_base, key)
    |> then(&Application.put_env(:tymeslot, @endpoint, &1))
  end

  defp assert_flags_reauth_on_401(integration) do
    ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 401, "Unauthorized") end)

    assert {:discard, _reason} =
             perform_job(SyncCalDavCalendarWorker, %{
               "calendar_integration_id" => integration.id
             })

    reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
    assert reloaded.needs_reauth == true
    assert reloaded.sync_error != nil
  end

  describe "perform/1 when the CalDAV server returns 401" do
    # Route CalDAV HTTP through the real HTTPClient so `Req.Test` can intercept
    # the PROPFIND the worker sends on the tier-detection probe.
    setup :set_req_test_to_shared

    setup do
      with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
      with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
      :ok
    end

    setup do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          base_url: "http://localhost:65432",
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("expired"),
          calendar_paths: ["/calendars/alice/default/"],
          provider_account_id: "http://localhost:65432||alice",
          is_active: true,
          needs_reauth: false
        )

      %{integration: integration}
    end

    test "flips needs_reauth and records a sync error", %{integration: integration} do
      # Every request the worker makes to the CalDAV server comes back 401,
      # mirroring a server-side credential rejection.
      assert_flags_reauth_on_401(integration)
    end
  end

  describe "perform/1 when the CalDAV server returns 401 mid-sync (after tier detection)" do
    # Route CalDAV HTTP through the real HTTPClient so `Req.Test` can intercept
    # the sync request the worker sends after tier detection is skipped.
    setup :set_req_test_to_shared

    setup do
      with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
      with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
      :ok
    end

    setup do
      # Pre-set caldav_sync_tier to 1 so maybe_detect_tier/2 bypasses the
      # tier-detection PROPFIND entirely and jumps straight into sync_tier1/2.
      # The first request the worker makes is the sync-collection REPORT, which
      # returns 401 — exercising the mid-sync flag_reauth_required/1 branch in
      # do_sync_tier1/3 rather than the tier-detection branch.
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          base_url: "http://localhost:65432",
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("expired"),
          calendar_paths: ["/calendars/alice/default/"],
          provider_account_id: "http://localhost:65432||alice",
          is_active: true,
          needs_reauth: false,
          caldav_sync_tier: 1
        )

      %{integration: integration}
    end

    test "flags needs_reauth and discards the job", %{integration: integration} do
      # Every request the worker makes returns 401 — the sync REPORT that fires
      # after tier detection was skipped hits the :unauthorized branch inside
      # do_sync_tier1/3, which calls flag_reauth_required/1.
      assert_flags_reauth_on_401(integration)
    end
  end

  describe "perform/1 when stored credentials cannot be decrypted" do
    test "flags the integration for reauth and discards the job without crashing" do
      put_secret_key(@key_a)
      integration = insert(:calendar_integration, provider: "caldav", is_active: true)
      refute integration.needs_reauth

      # The SECRET_KEY_BASE changed out from under the stored ciphertext (key
      # loss, not a planned rotation) — the credential can no longer decrypt.
      put_secret_key(@key_b)

      assert {:discard, reason} =
               perform_job(SyncCalDavCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert reason =~ "reauthentication"

      # Read the raw row — decrypt_credentials/1 would raise under the new key.
      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == true
      assert reloaded.sync_error =~ "could not be decrypted"
    end
  end

  describe "sweep filter" do
    test "stream_all_active skips integrations with needs_reauth: true" do
      put_secret_key(@key_a)
      healthy = insert(:calendar_integration, provider: "caldav", is_active: true)

      flagged =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          needs_reauth: true
        )

      ids =
        CalendarIntegrationQueries.stream_all_active(100, [], fn row, acc ->
          [row.id | acc]
        end)

      assert healthy.id in ids
      refute flagged.id in ids
    end
  end

  describe "clearing needs_reauth on reconnect" do
    test "update/2 with fresh credentials clears the flag" do
      put_secret_key(@key_a)

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          needs_reauth: true
        )

      {:ok, reconnected} =
        CalendarIntegrationQueries.update(integration, %{
          username: "user@example.com",
          password: "new-password"
        })

      refute reconnected.needs_reauth
    end

    test "update/2 without credential changes leaves the flag intact" do
      put_secret_key(@key_a)

      integration =
        insert(:calendar_integration,
          provider: "caldav",
          is_active: true,
          needs_reauth: true
        )

      {:ok, renamed} =
        CalendarIntegrationQueries.update(integration, %{name: "Renamed only"})

      assert renamed.needs_reauth
    end
  end
end
