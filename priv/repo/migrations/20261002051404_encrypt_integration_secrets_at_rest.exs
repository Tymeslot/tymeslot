defmodule Tymeslot.Repo.Migrations.EncryptIntegrationSecretsAtRest do
  @moduledoc """
  Encrypts four integration secrets that were stored in plain text, each into
  a new `*_encrypted` column:

    * `webhooks.url`: a Zapier, n8n or Make hook URL is itself the credential;
    * `video_integrations.custom_meeting_url`: a personal room link often
      carries its passcode;
    * `calendar_integrations.google_channel_secret` and `graph_client_state`:
      the values Google and Outlook push notifications are verified against.

  It also replaces the account key (`provider_account_id`) of custom video
  links, which was the link itself, with its SHA-256 (see
  `Tymeslot.Integrations.Video.AccountKey`). Hashing the stored key keeps two
  different keys different, so the partial unique index on account keys
  cannot be violated.

  ## The plain columns stay for now

  An image can be rolled back without this migration's `down/0` running, and
  the previous release reads only the plain columns. They are therefore kept,
  with their values, and the application stops reading them; `webhooks.url`
  loses its `NOT NULL` so new rows can leave it empty. A later release, once
  rolling back past this one is no longer supported, empties and drops them.

  A kept copy must never outlive its value. Whenever a secret changes (a
  webhook URL or meeting link edited, a push channel renewed), the same write
  empties its plain copy (`Tymeslot.Security.LegacyPlainColumn`). So under a
  rolled-back image a secret set or changed since this migration is simply
  missing, failing closed, rather than a value the user replaced coming back:
  a webhook never posts booking data to a URL its owner removed. Every
  untouched row keeps working.

  Encrypting needs the application's key, so the backfill calls
  `Tymeslot.Security.Encryption`, as earlier encryption backfills did. It only
  fills an encrypted column that is still empty, so running it again changes
  nothing.

  Rolling back writes each secret that decrypts back into its plain column,
  over whatever that column holds, since the encrypted value is the current
  one; a secret that no key opens leaves its row as it is. It then drops the
  encrypted columns. Custom video
  link keys stay hashed: they are not reversible, and the earlier release only
  uses them to refuse connecting the same link twice.
  """

  use Ecto.Migration

  alias Tymeslot.Security.Encryption

  # Backfills over values only the application can encrypt, and a key rewrite
  # with no migration DSL form; neither changes a column definition beyond the
  # nullable columns added here.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Only `down/0` removes columns, and only the ones `up/0` added.
  # excellent_migrations:safety-assured-for-this-file column_removed

  @columns [
    {"webhooks", "url"},
    {"video_integrations", "custom_meeting_url"},
    {"calendar_integrations", "google_channel_secret"},
    {"calendar_integrations", "graph_client_state"}
  ]

  @batch_size 500

  def up do
    alter table(:webhooks) do
      add(:url_encrypted, :binary)
    end

    alter table(:video_integrations) do
      add(:custom_meeting_url_encrypted, :binary)
    end

    alter table(:calendar_integrations) do
      add(:google_channel_secret_encrypted, :binary)
      add(:graph_client_state_encrypted, :binary)
    end

    execute("ALTER TABLE webhooks ALTER COLUMN url DROP NOT NULL")

    flush()

    execute(fn -> Enum.each(@columns, &encrypt_column/1) end)

    execute("""
    UPDATE video_integrations
    SET provider_account_id = encode(sha256(convert_to(provider_account_id, 'UTF8')), 'hex')
    WHERE provider = 'custom'
      AND provider_account_id IS NOT NULL
      AND provider_account_id !~ '^[0-9a-f]{64}$'
    """)
  end

  def down do
    execute(fn -> Enum.each(@columns, &restore_column/1) end)

    alter table(:calendar_integrations) do
      remove(:graph_client_state_encrypted)
      remove(:google_channel_secret_encrypted)
    end

    alter table(:video_integrations) do
      remove(:custom_meeting_url_encrypted)
    end

    alter table(:webhooks) do
      remove(:url_encrypted)
    end
  end

  defp encrypt_column({table, column}) do
    %{rows: rows} =
      repo().query!("""
      SELECT id, #{column} FROM #{table}
      WHERE #{column} IS NOT NULL AND #{column}_encrypted IS NULL
      ORDER BY id
      """)

    rows
    |> Enum.map(fn [id, value] -> [id, Encryption.encrypt(value)] end)
    |> write(table, "#{column}_encrypted", "bytea")
  end

  defp restore_column({table, column}) do
    %{rows: rows} =
      repo().query!("""
      SELECT id, #{column}_encrypted FROM #{table}
      WHERE #{column}_encrypted IS NOT NULL
      ORDER BY id
      """)

    rows
    |> Enum.flat_map(fn [id, ciphertext] ->
      case Encryption.decrypt_with_status(ciphertext) do
        {:ok, value} when is_binary(value) -> [[id, value]]
        _unreadable -> []
      end
    end)
    |> write(table, column, "text")
  end

  defp write(rows, table, column, type) do
    rows
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      [ids, values] = Enum.zip_with(batch, & &1)

      repo().query!(
        """
        UPDATE #{table} AS t SET #{column} = d.value
        FROM unnest($1::bigint[], $2::#{type}[]) AS d(id, value)
        WHERE t.id = d.id
        """,
        [ids, values]
      )
    end)
  end
end
