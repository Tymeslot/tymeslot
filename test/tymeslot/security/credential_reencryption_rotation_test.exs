defmodule Tymeslot.Security.CredentialReencryptionRotationTest do
  @moduledoc """
  The sweep is how a rotated key's values move to the new primary. These are
  the ways it can go wrong while it runs: the primary changes again part-way,
  the sweep dies part-way, a concurrent write wins a row. In each, no value may
  be lost, and the counts must say exactly what is left to do.
  """

  # async: false: swaps the global keyring, and the race test adds a trigger.
  use Tymeslot.DataCase, async: false

  @moduletag :security
  @moduletag :integration

  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Security.CredentialReencryption
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Telegram.TelegramIntegrationSchema

  @key_1 Base.encode64(:crypto.strong_rand_bytes(48))
  @key_2 Base.encode64(:crypto.strong_rand_bytes(48))
  @key_3 Base.encode64(:crypto.strong_rand_bytes(48))

  @video_columns [:api_key_encrypted, :access_token_encrypted, :refresh_token_encrypted]

  setup do
    original = Application.get_env(:tymeslot, Encryption)

    on_exit(fn ->
      Application.put_env(:tymeslot, Encryption, original)
      Encryption.reset_keyring()
    end)

    put_keys(data_encryption_key: @key_1)
    :ok
  end

  test "a rotation moves every value to the new key and leaves none on the old one" do
    integration = insert_video("a")

    put_keys(data_encryption_key: @key_1, data_encryption_keys: "2:#{@key_2},1:#{@key_1}")

    assert {:ok, %{tables: %{"video_integrations" => video}}} = CredentialReencryption.run()
    assert video.migrated_values >= 3

    assert_columns(integration, "a", on: 2)
    refute Map.has_key?(CredentialReencryption.key_report().totals, 1)
  end

  test "an OAuth flow started before a rotation completes after the old key is removed" do
    user = insert(:user)
    {:ok, %{nonce: nonce, code_challenge: challenge}} = PendingFlow.start(user.id, :google)

    put_keys(data_encryption_keys: "2:#{@key_2},1:#{@key_1}")

    assert {:ok, %{tables: %{"oauth_pending_flows" => %{migrated_values: 1}}}} =
             CredentialReencryption.run()

    put_keys(data_encryption_keys: "2:#{@key_2}")

    assert {:ok, verifier} = PendingFlow.consume(nonce, user.id, :google)
    assert Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge
  end

  test "a primary that changes again part-way through a sweep loses nothing" do
    # Swept under key 2, until the operator promotes key 3 before it finished.
    swept = insert_video("swept")
    put_keys(data_encryption_keys: "2:#{@key_2},1:#{@key_1}")
    unswept_after_2 = insert_video("written under 2")
    move_columns(swept, @video_columns)

    put_keys(data_encryption_keys: "3:#{@key_3},2:#{@key_2},1:#{@key_1}")

    assert {:ok, %{tables: %{"video_integrations" => video}}} = CredentialReencryption.run()
    assert video.migrated_values >= 6

    assert_columns(swept, "swept", on: 3)
    assert_columns(unswept_after_2, "written under 2", on: 3)
  end

  test "a sweep that died part-way, even inside a row, finishes on a re-run and counts exactly" do
    rows = for n <- 1..3, do: insert_video("row #{n}")
    put_keys(data_encryption_keys: "2:#{@key_2},1:#{@key_1}")

    # The first run got through one row and one column of the next.
    [done, half, _untouched] = rows
    move_columns(done, @video_columns)
    move_columns(half, [:api_key_encrypted])

    assert {:ok, %{tables: %{"video_integrations" => video}}} = CredentialReencryption.run()
    # Two columns of the half-done row and all three of the untouched one.
    assert video.migrated_values == 5
    assert video.migrated_rows == 2

    for {row, n} <- Enum.with_index(rows, 1), do: assert_columns(row, "row #{n}", on: 2)

    assert {:ok, %{totals: %{migrated_values: 0}}} = CredentialReencryption.run()
  end

  test "a column whose compare-and-swap loses to a concurrent write is not counted" do
    integration =
      insert(:telegram_integration, bot_token_encrypted: Encryption.encrypt("bot-token"))

    put_keys(data_encryption_keys: "2:#{@key_2},1:#{@key_1}")

    # Skipping the row update is exactly what a lost CAS looks like to the sweep:
    # the UPDATE matches, and no row is written.
    Repo.query!("""
    CREATE FUNCTION pg_temp.skip_update() RETURNS trigger AS $$
    BEGIN RETURN NULL; END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER skip_update BEFORE UPDATE ON telegram_integrations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.skip_update()
    """)

    assert {:ok, %{tables: %{"telegram_integrations" => telegram}}} = CredentialReencryption.run()
    assert telegram.migrated_values == 0
    assert telegram.migrated_rows == 0

    Repo.query!("DROP TRIGGER skip_update ON telegram_integrations")

    assert {:ok, %{tables: %{"telegram_integrations" => %{migrated_values: 1}}}} =
             CredentialReencryption.run()

    stored = Repo.get!(TelegramIntegrationSchema, integration.id).bot_token_encrypted
    assert Encryption.key_version(stored) == {:ok, 2}
    assert Encryption.decrypt(stored) == "bot-token"
  end

  defp put_keys(config) do
    Application.put_env(:tymeslot, Encryption, config)
    Encryption.reset_keyring()
  end

  defp insert_video(label) do
    insert(:video_integration,
      api_key_encrypted: Encryption.encrypt("#{label} api key"),
      access_token_encrypted: Encryption.encrypt("#{label} access"),
      refresh_token_encrypted: Encryption.encrypt("#{label} refresh"),
      tenant_id_encrypted: nil,
      client_id_encrypted: nil,
      client_secret_encrypted: nil,
      teams_user_id_encrypted: nil
    )
  end

  # Re-encrypts the given columns of a row under the current primary, as a
  # sweep that reached them would have.
  defp move_columns(integration, columns) do
    row = Repo.get!(VideoIntegrationSchema, integration.id)
    changes = for column <- columns, do: {column, row |> Map.fetch!(column) |> reencrypt()}

    Repo.update_all(from(v in VideoIntegrationSchema, where: v.id == ^integration.id),
      set: changes
    )
  end

  defp reencrypt(ciphertext), do: ciphertext |> Encryption.decrypt() |> Encryption.encrypt()

  defp assert_columns(integration, label, on: version) do
    row = Repo.get!(VideoIntegrationSchema, integration.id)

    expected = %{
      api_key_encrypted: "#{label} api key",
      access_token_encrypted: "#{label} access",
      refresh_token_encrypted: "#{label} refresh"
    }

    for {column, plaintext} <- expected do
      stored = Map.fetch!(row, column)

      assert Encryption.key_version(stored) == {:ok, version},
             "#{column} is not on key #{version}"

      assert Encryption.decrypt(stored) == plaintext
    end
  end
end
