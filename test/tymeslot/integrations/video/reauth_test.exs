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
  use Tymeslot.DataCase, async: false

  @moduletag :video
  @moduletag :security

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

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

  describe "VideoIntegrationQueries.get/1 with a stale encryption key" do
    test "returns {:error, :requires_reencryption, integration} when credentials were encrypted under a different key" do
      put_secret_key(@key_a)

      integration =
        insert(:video_integration,
          provider: "mirotalk",
          is_active: true,
          api_key_encrypted: Encryption.encrypt("my-api-key")
        )

      # Simulate key rotation without re-encrypting existing rows.
      put_secret_key(@key_b)

      assert {:error, :requires_reencryption, stale} =
               VideoIntegrationQueries.get(integration.id)

      assert stale.id == integration.id
    end
  end

  describe "Video.handle_reauth_required/1" do
    test "sets needs_reauth: true and returns {:discard, reason} containing 'reauthentication'" do
      put_secret_key(@key_a)

      integration =
        insert(:video_integration,
          provider: "mirotalk",
          is_active: true,
          api_key_encrypted: Encryption.encrypt("my-api-key")
        )

      put_secret_key(@key_b)

      {:error, :requires_reencryption, stale} = VideoIntegrationQueries.get(integration.id)

      assert {:discard, reason} = Video.handle_reauth_required(stale)
      assert reason =~ "reauthentication"

      reloaded = Repo.get!(VideoIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == true
    end

    test "records a sync_error after handle_reauth_required/1" do
      put_secret_key(@key_a)

      integration =
        insert(:video_integration,
          provider: "mirotalk",
          is_active: true,
          api_key_encrypted: Encryption.encrypt("my-api-key")
        )

      put_secret_key(@key_b)

      {:error, :requires_reencryption, stale} = VideoIntegrationQueries.get(integration.id)

      {:discard, _reason} = Video.handle_reauth_required(stale)

      reloaded = Repo.get!(VideoIntegrationSchema, integration.id)
      assert reloaded.sync_error =~ "could not be decrypted"
    end
  end

  describe "VideoIntegrationQueries.update/2 clearing needs_reauth on reconnect" do
    test "update/2 with fresh credentials clears the flag" do
      put_secret_key(@key_a)

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
