defmodule Tymeslot.ReleaseEncryptionTest do
  # async: false: one test swaps the global keyring held in :persistent_term.
  use Tymeslot.DataCase, async: false

  @moduletag :security

  import ExUnit.CaptureIO

  alias Tymeslot.Release.Encryption, as: ReleaseEncryption
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Test.LegacyCiphertext

  describe "key_report/0" do
    test "prints each column's counts by key version and returns the report" do
      legacy = LegacyCiphertext.encrypt("legacy-token")
      insert(:telegram_integration, bot_token_encrypted: legacy)

      {report, output} = with_io(&ReleaseEncryption.key_report/0)

      assert report.tables["telegram_integrations"][:bot_token_encrypted] == %{0 => 1}
      assert output =~ "telegram_integrations.bot_token_encrypted: v0 1, unreadable 0\n"
      assert output =~ ~r/^total: v0 1, unreadable 0$/m
      refute output =~ "legacy-token"
      refute output =~ Base.encode64(legacy)
    end
  end

  describe "reencrypt_credentials/0" do
    test "migrates legacy values and prints the totals" do
      integration =
        insert(:telegram_integration,
          bot_token_encrypted: LegacyCiphertext.encrypt("legacy-token")
        )

      {result, output} = with_io(&ReleaseEncryption.reencrypt_credentials/0)

      assert {:ok, %{totals: %{migrated_values: 1}}} = result
      assert output =~ "migrated values: 1, rows: 1,"

      stored = Repo.get!(TelegramIntegrationSchema, integration.id).bot_token_encrypted
      assert Encryption.current?(stored)
      assert Encryption.decrypt(stored) == "legacy-token"
    end

    test "says so when there is no data encryption key to migrate to" do
      original = Application.get_env(:tymeslot, Encryption)

      on_exit(fn ->
        Application.put_env(:tymeslot, Encryption, original)
        Encryption.reset_keyring()
      end)

      Application.put_env(:tymeslot, Encryption, data_encryption_key: nil)
      Encryption.reset_keyring()

      {result, output} = with_io(&ReleaseEncryption.reencrypt_credentials/0)

      assert result == {:error, :not_configured}
      assert output =~ "No data encryption key is configured"
    end
  end
end
