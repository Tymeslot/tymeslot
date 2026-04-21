defmodule Tymeslot.Workers.SyncOutlookCalendarWorkerReauthTest do
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

  use Oban.Testing, repo: Tymeslot.Repo

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

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

  describe "perform/1 when stored credentials cannot be decrypted" do
    test "flags the integration for reauth and discards the job without crashing" do
      put_secret_key(@key_a)

      integration =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token")
        )

      refute integration.needs_reauth

      # The SECRET_KEY_BASE changed out from under the stored ciphertext (key
      # loss, not a planned rotation) — the credential can no longer decrypt.
      put_secret_key(@key_b)

      assert {:discard, reason} =
               perform_job(SyncOutlookCalendarWorker, %{
                 "calendar_integration_id" => integration.id,
                 "graph_resource_id" => "AAMkADExampleResourceId00001"
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
    test "update/2 with fresh credentials clears the flag" do
      put_secret_key(@key_a)

      integration =
        insert(:calendar_integration,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: Encryption.encrypt("test-access-token"),
          refresh_token_encrypted: Encryption.encrypt("test-refresh-token"),
          needs_reauth: true
        )

      {:ok, reconnected} =
        CalendarIntegrationQueries.update(integration, %{
          access_token: "new-access-token",
          refresh_token: "new-refresh-token"
        })

      refute reconnected.needs_reauth
    end

    test "update/2 without credential changes leaves the flag intact" do
      put_secret_key(@key_a)

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
