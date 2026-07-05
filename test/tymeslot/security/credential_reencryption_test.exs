defmodule Tymeslot.Security.CredentialReencryptionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :security
  @moduletag :integration

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.EncryptedStorage
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Slack
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.WebhookSchema

  # {context, table_name} — every context the sweep is expected to cover.
  # Keeping this list here, alongside the guard test below, means a context
  # gaining a new `*_encrypted` field without updating its
  # `encrypted_storage/0` fails this test rather than silently stranding a
  # secret on the legacy key.
  @covered_contexts [
    {Calendar, "calendar_integrations"},
    {Video, "video_integrations"},
    {Slack, "slack_integrations"},
    {Telegram, "telegram_integrations"},
    {Webhooks, "webhooks"}
  ]

  defp reload_token(schema, id) do
    Repo.get!(schema, id).bot_token_encrypted
  end

  describe "run/1" do
    test "migrates legacy v0 values to the current version and leaves current values untouched" do
      legacy =
        insert(:telegram_integration,
          bot_token_encrypted: Encryption.encrypt_legacy("legacy-bot-token")
        )

      current =
        insert(:slack_integration, bot_token_encrypted: Encryption.encrypt("current-token"))

      refute Encryption.current?(legacy.bot_token_encrypted)
      assert Encryption.current?(current.bot_token_encrypted)

      assert {:ok, %{tables: tables, totals: totals}} = CredentialReencryption.run()

      # The legacy telegram token is now stored under the current key and still
      # decrypts to the original secret.
      migrated = reload_token(TelegramIntegrationSchema, legacy.id)
      assert Encryption.current?(migrated)
      assert Encryption.decrypt(migrated) == "legacy-bot-token"

      # The already-current slack token was left byte-for-byte untouched.
      assert reload_token(SlackIntegrationSchema, current.id) == current.bot_token_encrypted

      assert totals.migrated_values >= 1
      assert %{migrated_values: telegram_migrated} = tables["telegram_integrations"]
      assert telegram_migrated >= 1
      assert %{already_current: slack_already} = tables["slack_integrations"]
      assert slack_already >= 1
    end

    test "a second run is a no-op" do
      insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt_legacy("token"))

      assert {:ok, %{totals: %{migrated_values: first}}} = CredentialReencryption.run()
      assert first >= 1

      assert {:ok, %{totals: %{migrated_values: 0}}} = CredentialReencryption.run()
    end

    test "leaves unrecoverable values in place and reports them" do
      # A value that verifies under no available key (random bytes long enough to
      # look like a versioned envelope) must not be rewritten or crash the sweep.
      garbage = :crypto.strong_rand_bytes(40)
      integration = insert(:telegram_integration, bot_token_encrypted: garbage)

      assert {:ok, %{totals: totals}} = CredentialReencryption.run()

      assert totals.unrecoverable >= 1
      assert reload_token(TelegramIntegrationSchema, integration.id) == garbage
    end

    test "migrates every legacy column on a multi-column row and counts them all" do
      legacy_calendar =
        insert(:calendar_integration,
          provider: "google",
          username_encrypted: Encryption.encrypt_legacy("legacy-username"),
          password_encrypted: Encryption.encrypt_legacy("legacy-password"),
          access_token_encrypted: Encryption.encrypt_legacy("legacy-access-token"),
          refresh_token_encrypted: Encryption.encrypt_legacy("legacy-refresh-token")
        )

      legacy_video =
        insert(:video_integration,
          provider: "teams",
          api_key_encrypted: Encryption.encrypt_legacy("legacy-api-key"),
          access_token_encrypted: Encryption.encrypt_legacy("legacy-access-token"),
          refresh_token_encrypted: Encryption.encrypt_legacy("legacy-refresh-token"),
          client_id_encrypted: Encryption.encrypt_legacy("legacy-client-id"),
          client_secret_encrypted: Encryption.encrypt_legacy("legacy-client-secret"),
          tenant_id_encrypted: Encryption.encrypt_legacy("legacy-tenant-id"),
          teams_user_id_encrypted: Encryption.encrypt_legacy("legacy-teams-user-id")
        )

      assert {:ok, %{tables: tables}} = CredentialReencryption.run()

      reloaded_calendar = Repo.get!(CalendarIntegrationSchema, legacy_calendar.id)

      calendar_pairs = [
        {reloaded_calendar.username_encrypted, "legacy-username"},
        {reloaded_calendar.password_encrypted, "legacy-password"},
        {reloaded_calendar.access_token_encrypted, "legacy-access-token"},
        {reloaded_calendar.refresh_token_encrypted, "legacy-refresh-token"}
      ]

      for {ciphertext, plaintext} <- calendar_pairs do
        assert Encryption.current?(ciphertext)
        assert Encryption.decrypt(ciphertext) == plaintext
      end

      reloaded_video = Repo.get!(VideoIntegrationSchema, legacy_video.id)

      video_pairs = [
        {reloaded_video.api_key_encrypted, "legacy-api-key"},
        {reloaded_video.access_token_encrypted, "legacy-access-token"},
        {reloaded_video.refresh_token_encrypted, "legacy-refresh-token"},
        {reloaded_video.client_id_encrypted, "legacy-client-id"},
        {reloaded_video.client_secret_encrypted, "legacy-client-secret"},
        {reloaded_video.tenant_id_encrypted, "legacy-tenant-id"},
        {reloaded_video.teams_user_id_encrypted, "legacy-teams-user-id"}
      ]

      for {ciphertext, plaintext} <- video_pairs do
        assert Encryption.current?(ciphertext)
        assert Encryption.decrypt(ciphertext) == plaintext
      end

      assert %{migrated_rows: calendar_rows, migrated_values: calendar_values} =
               tables["calendar_integrations"]

      assert calendar_rows == 1
      assert calendar_values == length(calendar_pairs)

      assert %{migrated_rows: video_rows, migrated_values: video_values} =
               tables["video_integrations"]

      assert video_rows == 1
      assert video_values == length(video_pairs)
    end
  end

  describe "covered_tables/0" do
    test "every covered context implements the EncryptedStorage behaviour" do
      for {context, _table} <- @covered_contexts do
        assert EncryptedStorage in (context.module_info(:attributes)[:behaviour] || []),
               "expected #{inspect(context)} to implement Tymeslot.Security.EncryptedStorage"
      end
    end

    test "covers exactly the tables of every context expected to be swept" do
      covered = Map.new(CredentialReencryption.covered_tables())

      assert Enum.sort(Map.keys(covered)) ==
               Enum.sort(Enum.map(@covered_contexts, fn {_context, table} -> table end))
    end

    test "every schema's encrypted_credential_fields/0 matches its actual *_encrypted columns" do
      # A new `*_encrypted` field added to a schema but never added to
      # `encrypted_credential_fields/0` would silently strand that column on
      # the legacy key forever — the sweep only ever sees the declared list.
      schemas = [
        CalendarIntegrationSchema,
        VideoIntegrationSchema,
        SlackIntegrationSchema,
        TelegramIntegrationSchema,
        WebhookSchema
      ]

      for schema <- schemas do
        actual_encrypted_fields =
          schema.__schema__(:fields)
          |> Enum.filter(&String.ends_with?(to_string(&1), "_encrypted"))
          |> Enum.sort()

        assert actual_encrypted_fields != [],
               "expected #{inspect(schema)} to declare at least one *_encrypted field"

        assert actual_encrypted_fields == Enum.sort(schema.encrypted_credential_fields()),
               "expected #{inspect(schema)}.encrypted_credential_fields/0 to match its actual *_encrypted schema fields"
      end
    end
  end
end
