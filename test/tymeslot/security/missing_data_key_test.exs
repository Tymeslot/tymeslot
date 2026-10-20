defmodule Tymeslot.Security.MissingDataKeyTest do
  @moduledoc """
  A data key dropped from the keyring while values remain under its id is an
  operator mistake that adding the key back undoes. The boot check names the
  missing id with its counts, and the paths that meet such a value neither
  flag the integration for reconnection nor email its owner.
  """

  # async: false: swaps the global keyring held in :persistent_term, and
  # captures logs.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :security
  @moduletag :integration
  @moduletag :capture_log

  import ExUnit.CaptureIO

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Release.Encryption, as: ReleaseEncryption
  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.CredentialReencryption.KeyReport
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Test.LogCapture
  alias Tymeslot.Workers.EmailWorker

  @key_1 Base.encode64(:crypto.strong_rand_bytes(48))
  @key_2 Base.encode64(:crypto.strong_rand_bytes(48))

  setup do
    original = Application.get_env(:tymeslot, Encryption)

    on_exit(fn ->
      Application.put_env(:tymeslot, Encryption, original)
      Encryption.reset_keyring()
    end)

    # Written under key 1, then the operator promotes key 2 and drops key 1
    # before the sweep has moved anything.
    put_keys("1:#{@key_1}")
    :ok
  end

  describe "absent_key_version/1" do
    test "names a dropped id below the primary, and nothing once the key is back" do
      value = Encryption.encrypt("secret")

      put_keys("2:#{@key_2}")
      assert Encryption.absent_key_version(value) == {:ok, 1}

      put_keys("2:#{@key_2},1:#{@key_1}")
      assert Encryption.absent_key_version(value) == :error
      assert Encryption.decrypt(value) == "secret"
    end

    test "names id 1 when every versioned key is gone" do
      value = Encryption.encrypt("secret")

      put_keys(nil)
      assert Encryption.absent_key_version(value) == {:ok, 1}
    end

    test "does not take an id above every configured one for a dropped key" do
      put_keys("3:#{@key_2}")
      value = Encryption.encrypt("secret")

      put_keys("2:#{@key_1}")
      assert Encryption.absent_key_version(value) == :error
    end

    test "names nothing for an empty value" do
      put_keys("2:#{@key_2}")
      assert Encryption.absent_key_version(nil) == :error
    end
  end

  describe "the key report" do
    test "counts values under a dropped id under that id and lists it as missing" do
      insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("old"))
      put_keys("2:#{@key_2}")
      insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("new"))

      report = CredentialReencryption.key_report()

      assert report.tables["telegram_integrations"][:bot_token_encrypted] == %{1 => 1, 2 => 1}
      assert report.missing_keys == %{1 => %{"telegram_integrations.bot_token_encrypted" => 1}}
    end

    test "the release helper names the missing id on a line of its own" do
      insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("old"))
      put_keys("2:#{@key_2}")

      {_report, output} = with_io(&ReleaseEncryption.key_report/0)

      assert output =~ "telegram_integrations.bot_token_encrypted: v1 1, unreadable 0\n"

      assert output =~
               ~r/^key 1 is not configured but holds values \(1\): add it back under the same id$/m
    end

    test "lists nothing missing while every id holding values is configured" do
      insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("old"))
      put_keys("2:#{@key_2},1:#{@key_1}")

      assert CredentialReencryption.key_report().missing_keys == %{}
    end
  end

  describe "the boot check" do
    setup do
      LogCapture.attach()
      :ok
    end

    test "names the missing id, its counts and the fix, without LEGACY_KEY_RETIRED" do
      %{bot_token_encrypted: ciphertext} =
        insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("old"))

      put_keys("2:#{@key_2}")
      refute Encryption.legacy_key_retired?()

      KeyReport.warn_about_unreadable_values()

      assert_receive {:captured_log,
                      %{level: :error, meta: %{event_type: "encryption_key_missing"}} = event}

      assert event.meta.missing_key_ids == [1]

      assert event.meta.missing_key_values == [
               %{key_id: 1, column: "telegram_integrations.bot_token_encrypted", count: 1}
             ]

      message = LogCapture.message_text(event.msg)
      assert message =~ "key 1 (telegram_integrations.bot_token_encrypted: 1)"
      assert message =~ "Add the key with id 1 back to DATA_ENCRYPTION_KEYS"
      refute message =~ Base.encode64(ciphertext)
    end

    test "stays silent while every id holding values is configured" do
      insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("old"))
      put_keys("2:#{@key_2},1:#{@key_1}")

      KeyReport.warn_about_unreadable_values()

      refute_receive {:captured_log, %{meta: %{event_type: "encryption_key_missing"}}}
    end
  end

  describe "an integration whose credentials are under the dropped key" do
    test "a token refresh neither flags it nor emails its owner, and re-adding the key recovers it" do
      integration =
        insert(:calendar_integration,
          user: insert(:user),
          provider: "google",
          access_token_encrypted: Encryption.encrypt("old-access"),
          refresh_token_encrypted: Encryption.encrypt("old-refresh"),
          token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      held = CalendarIntegrationSchema.decrypt_credentials(integration)
      put_keys("2:#{@key_2}")

      assert {:error, :requires_reencryption} = Tokens.refresh_oauth_token(held)

      stored = Repo.get!(CalendarIntegrationSchema, integration.id)
      refute stored.needs_reauth
      assert stored.sync_error == nil
      refute_enqueued(worker: EmailWorker)

      put_keys("2:#{@key_2},1:#{@key_1}")

      assert {:ok, %{access_token: "old-access"}} =
               Management.fetch_integration_for_user(integration.id, integration.user_id)
    end

    test "a calendar job discards it as an operator problem, not a reconnect" do
      integration =
        insert(:calendar_integration,
          user: insert(:user),
          username_encrypted: Encryption.encrypt("cal-user")
        )

      put_keys("2:#{@key_2}")

      assert Management.handle_reauth_required(integration) ==
               {:discard, ReauthHandling.key_missing_discard_reason()}

      refute Repo.get!(CalendarIntegrationSchema, integration.id).needs_reauth
      refute_enqueued(worker: EmailWorker)
    end

    test "a video job discards it as an operator problem, not a reconnect" do
      integration =
        insert(:video_integration,
          user: insert(:user),
          api_key_encrypted: Encryption.encrypt("video-key")
        )

      put_keys("2:#{@key_2}")

      assert Video.handle_reauth_required(integration) ==
               {:discard, ReauthHandling.key_missing_discard_reason()}

      refute Repo.get!(VideoIntegrationSchema, integration.id).needs_reauth
      refute_enqueued(worker: EmailWorker)
    end

    test "credentials that are corrupt rather than under a dropped key are still flagged" do
      integration =
        :calendar_integration
        |> insert(user: insert(:user))
        |> Changeset.change(username_encrypted: <<1>> <> :crypto.strong_rand_bytes(40))
        |> Repo.update!()

      # Key 1 is configured, so the value is corrupt, not under a missing key.
      assert Management.handle_reauth_required(integration) ==
               {:discard, ReauthHandling.discard_reason()}

      assert Repo.get!(CalendarIntegrationSchema, integration.id).needs_reauth
    end
  end

  test "an OAuth flow whose verifier is under the dropped key is not found, not a crash" do
    user = insert(:user)
    {:ok, %{nonce: nonce}} = PendingFlow.start(user.id, :google)

    put_keys("2:#{@key_2}")

    assert PendingFlow.consume(nonce, user.id, :google) == {:error, :flow_not_found}
  end

  defp put_keys(keys) do
    Application.put_env(:tymeslot, Encryption, data_encryption_keys: keys)
    Encryption.reset_keyring()
  end
end
