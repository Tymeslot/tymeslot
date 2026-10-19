defmodule Tymeslot.Security.CredentialReencryptionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :security
  @moduletag :integration

  alias Ecto.UUID
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.EncryptedStorage
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Test.LegacyCiphertext
  alias Tymeslot.Webhooks.WebhookSchema

  defp reload_token(schema, id) do
    Repo.get!(schema, id).bot_token_encrypted
  end

  setup_all do
    {:ok, modules} = :application.get_key(:tymeslot, :modules)
    Enum.each(modules, &Code.ensure_loaded!/1)
    %{modules: modules}
  end

  describe "run/1" do
    test "migrates legacy v0 values to the current version and leaves current values untouched" do
      legacy =
        insert(:telegram_integration,
          bot_token_encrypted: LegacyCiphertext.encrypt("legacy-bot-token")
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

    test "migrates a legacy value behind an EncryptedString field" do
      webhook = insert(:webhook)

      Repo.update_all(from(w in "webhooks", where: w.id == ^webhook.id),
        set: [url_encrypted: LegacyCiphertext.encrypt("https://hooks.example.com/legacy")]
      )

      assert {:ok, %{tables: %{"webhooks" => %{migrated_values: 1}}}} =
               CredentialReencryption.run()

      %{rows: [[stored]]} =
        Repo.query!("SELECT url_encrypted FROM webhooks WHERE id = $1", [webhook.id])

      assert Encryption.current?(stored)
      assert Repo.get!(WebhookSchema, webhook.id).url == "https://hooks.example.com/legacy"
    end

    test "migrates a legacy value in a table keyed by UUID" do
      # The keyset pages start from no id, which a UUID key can be compared
      # with, where an integer 0 could not.
      polls = insert_list(3, :poll)

      for poll <- polls do
        Repo.query!("UPDATE polls SET token_encrypted = $1 WHERE id = $2", [
          LegacyCiphertext.encrypt(poll.token),
          UUID.dump!(poll.id)
        ])
      end

      assert {:ok, %{tables: %{"polls" => %{migrated_values: 3}}}} =
               CredentialReencryption.run(batch_size: 2)

      for poll <- polls do
        assert Repo.get!(PollSchema, poll.id).token == poll.token
      end
    end

    test "a second run is a no-op" do
      insert(:telegram_integration, bot_token_encrypted: LegacyCiphertext.encrypt("token"))

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
          username_encrypted: LegacyCiphertext.encrypt("legacy-username"),
          password_encrypted: LegacyCiphertext.encrypt("legacy-password"),
          access_token_encrypted: LegacyCiphertext.encrypt("legacy-access-token"),
          refresh_token_encrypted: LegacyCiphertext.encrypt("legacy-refresh-token")
        )

      legacy_video =
        insert(:video_integration,
          provider: "teams",
          api_key_encrypted: LegacyCiphertext.encrypt("legacy-api-key"),
          access_token_encrypted: LegacyCiphertext.encrypt("legacy-access-token"),
          refresh_token_encrypted: LegacyCiphertext.encrypt("legacy-refresh-token"),
          client_id_encrypted: LegacyCiphertext.encrypt("legacy-client-id"),
          client_secret_encrypted: LegacyCiphertext.encrypt("legacy-client-secret"),
          tenant_id_encrypted: LegacyCiphertext.encrypt("legacy-tenant-id"),
          teams_user_id_encrypted: LegacyCiphertext.encrypt("legacy-teams-user-id")
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
    # Derived from the compiled application rather than kept by hand, so a new
    # schema, context or encrypted column is checked the moment it exists.
    # `:application.get_key/2` lists every module, loaded or not, which is
    # what a release (loading modules lazily) needs too. Loading them all can
    # outlast a test's 60 s timeout on a loaded machine, so it is done once,
    # in `setup_all`, which the timeout does not cover.

    test "sweeps every encrypted column of every schema", %{modules: modules} do
      expected = MapSet.new(encrypted_columns(modules))

      covered =
        MapSet.new(
          for {table, columns} <- CredentialReencryption.covered_tables(),
              column <- columns,
              do: {table, column}
        )

      assert MapSet.size(expected) > 0
      assert MapSet.difference(expected, covered) == MapSet.new(), "not swept"
      assert MapSet.difference(covered, expected) == MapSet.new(), "swept but not encrypted"
    end

    test "every context implementing EncryptedStorage is swept", %{modules: modules} do
      implementers =
        Enum.filter(modules, fn module ->
          EncryptedStorage in (module.module_info(:attributes)
                               |> Keyword.get_values(:behaviour)
                               |> List.flatten())
        end)

      assert implementers != []

      declared = Enum.flat_map(implementers, &List.wrap(&1.encrypted_storage()))
      assert Enum.sort(declared) == Enum.sort(CredentialReencryption.covered_tables())
    end

    test "every encrypted_credential_fields/0 matches its schema's *_encrypted fields", %{
      modules: modules
    } do
      # A new `*_encrypted` field added to a schema but never added to
      # `encrypted_credential_fields/0` would silently strand that column on
      # the legacy key forever — the sweep only ever sees the declared list.
      schemas = Enum.filter(modules, &function_exported?(&1, :encrypted_credential_fields, 0))

      assert schemas != []

      for schema <- schemas do
        actual =
          schema.__schema__(:fields)
          |> Enum.filter(&String.ends_with?(to_string(&1), "_encrypted"))
          |> Enum.sort()

        assert actual == Enum.sort(schema.encrypted_credential_fields()),
               "expected #{inspect(schema)}.encrypted_credential_fields/0 to match its *_encrypted fields"
      end
    end
  end

  # `{table, column}` for every column a schema encrypts: a field typed
  # `EncryptedString` (stored under a `*_encrypted` source), or a binary field
  # holding ciphertext under a `*_encrypted` name.
  defp encrypted_columns(modules) do
    for module <- modules,
        function_exported?(module, :__schema__, 1),
        table = module.__schema__(:source),
        is_binary(table),
        field <- module.__schema__(:fields),
        column = module.__schema__(:field_source, field),
        module.__schema__(:type, field) == EncryptedString or
          String.ends_with?(to_string(column), "_encrypted"),
        uniq: true,
        do: {table, column}
  end
end
