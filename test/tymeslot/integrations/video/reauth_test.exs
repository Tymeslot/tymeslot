defmodule Tymeslot.Integrations.Video.ReauthTest do
  @moduledoc """
  Covers the reauth detection and recovery path for video integrations.

  When stored credentials were encrypted under a different SECRET_KEY_BASE,
  the queries layer must surface `{:error, :requires_reencryption, integration}`
  rather than silently returning nil for every credential. The context's
  `handle_reauth_required/1` must then flag the integration and return
  `{:discard, _}` so Oban jobs don't crash or loop indefinitely.

  Once the user reconnects and supplies fresh credentials, `update/2` must
  clear the flag.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :video
  @moduletag :security

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  describe "VideoIntegrationQueries.get/1 with a stale encryption key" do
    test "returns {:error, :requires_reencryption, integration} when credentials were encrypted under a different key" do
      # A credential whose key is genuinely gone (or a corrupt value) verifies
      # under no key in the keyring. Decoupling the data key from SECRET_KEY_BASE
      # means rotating the session secret no longer does this — so simulate real
      # key loss with undecryptable bytes.
      integration =
        insert(:video_integration,
          provider: "mirotalk",
          is_active: true,
          api_key_encrypted: :crypto.strong_rand_bytes(40)
        )

      assert {:error, :requires_reencryption, stale} =
               VideoIntegrationQueries.get(integration.id)

      assert stale.id == integration.id
    end
  end

  describe "Video.handle_reauth_required/1" do
    test "sets needs_reauth: true and returns {:discard, reason} containing 'reauthentication'" do
      # Undecryptable bytes stand in for a credential whose key is genuinely gone
      # (rotating SECRET_KEY_BASE no longer produces this — see decoupling).
      integration =
        insert(:video_integration,
          provider: "mirotalk",
          is_active: true,
          api_key_encrypted: :crypto.strong_rand_bytes(40)
        )

      {:error, :requires_reencryption, stale} = VideoIntegrationQueries.get(integration.id)

      assert {:discard, reason} = Video.handle_reauth_required(stale)
      assert reason =~ "reauthentication"

      reloaded = Repo.get!(VideoIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == true
    end

    test "records a sync_error after handle_reauth_required/1" do
      # Undecryptable bytes stand in for a credential whose key is genuinely gone
      # (rotating SECRET_KEY_BASE no longer produces this — see decoupling).
      integration =
        insert(:video_integration,
          provider: "mirotalk",
          is_active: true,
          api_key_encrypted: :crypto.strong_rand_bytes(40)
        )

      {:error, :requires_reencryption, stale} = VideoIntegrationQueries.get(integration.id)

      {:discard, _reason} = Video.handle_reauth_required(stale)

      reloaded = Repo.get!(VideoIntegrationSchema, integration.id)
      assert reloaded.sync_error =~ "could not be decrypted"
    end
  end

  describe "VideoIntegrationQueries.update/2 clearing needs_reauth on reconnect" do
    test "update/2 with fresh credentials clears the flag" do
      integration =
        insert(:video_integration,
          provider: "mirotalk",
          is_active: true,
          api_key_encrypted: Encryption.encrypt("my-api-key"),
          needs_reauth: true
        )

      {:ok, reconnected} =
        VideoIntegrationQueries.update(integration, %{api_key: "new-api-key"})

      refute reconnected.needs_reauth
    end
  end
end
