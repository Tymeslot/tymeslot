defmodule Tymeslot.Workers.SyncOutlookCalendarWorkerReauthTest do
  @moduledoc """
  A sync worker that encounters a credential it cannot decrypt must flag the
  integration as `needs_reauth` and complete the Oban job with `{:discard, _}`
  — never crash. Once the user reconnects, the flag must clear so the
  sweep-level `needs_reauth` filter doesn't keep the integration stranded.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :calendar
  @moduletag :security

  use Oban.Testing, repo: Tymeslot.Repo

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  describe "perform/1 when stored credentials cannot be decrypted" do
    test "flags the integration for reauth and discards the job without crashing" do
      # A credential encrypted under a key that is genuinely gone (or a corrupt
      # value) verifies under no key in the keyring. Since the data key is now
      # decoupled from SECRET_KEY_BASE, rotating the session secret no longer
      # produces this — so simulate real key loss with undecryptable bytes.
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: :crypto.strong_rand_bytes(40),
          refresh_token_encrypted: :crypto.strong_rand_bytes(40)
        )

      refute integration.needs_reauth

      assert {:discard, reason} =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "graph_resource_id" => "AAMkADExampleResourceId00001"
               })

      assert reason =~ "reauthentication"

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == true
      assert reloaded.sync_error =~ "could not be decrypted"
    end
  end

  describe "sweep filter" do
    test "stream_all_active skips integrations with needs_reauth: true" do
      healthy =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token")
        )

      flagged =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
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
    test "update_credentials/2 clears the flag" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
          needs_reauth: true
        )

      {:ok, reconnected} =
        CalendarIntegrationQueries.update_credentials(integration, %{
          access_token: "new-access-token",
          refresh_token: "new-refresh-token"
        })

      refute reconnected.needs_reauth
    end

    test "update/2 leaves the flag intact even when it writes tokens" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
          needs_reauth: true
        )

      {:ok, refreshed} =
        CalendarIntegrationQueries.update(integration, %{
          access_token: "new-access-token",
          refresh_token: "new-refresh-token"
        })

      assert refreshed.needs_reauth
    end

    test "update/2 without credential changes leaves the flag intact" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
          needs_reauth: true
        )

      {:ok, renamed} =
        CalendarIntegrationQueries.update(integration, %{name: "Renamed only"})

      assert renamed.needs_reauth
    end
  end
end
