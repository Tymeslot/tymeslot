defmodule Tymeslot.Repo.Migrations.HashTelegramLinkTokens do
  @moduledoc """
  Stores the shared Telegram bot's `/start` link token as its SHA-256 rather
  than as itself, the way session and password-reset tokens already are. The
  token is handed out once, in the deep link, and only compared afterwards,
  so its hash is enough to look it up by.

  `link_token_hash` is backfilled from the stored token with the same
  function as `Tymeslot.Security.Token.hash_token/1` (lower-case hex), and
  gets the unique index the lookup uses. Distinct tokens hash to distinct
  values, so the index meets no duplicate.

  ## The plain column stays for now

  An image can be rolled back without this migration's `down/0` running, and
  the previous release looks the token up in the plain `link_token` column.
  It is therefore kept, with its values, and the application stops reading
  and writing it. A later release, once rolling back past this one is no
  longer supported, empties and drops it.

  Rolling back drops the hash column. A link issued since then is not
  recoverable from its hash and has to be refreshed from the dashboard, which
  it would within ten minutes anyway.
  """

  use Ecto.Migration

  # A backfill computing a value from another column, which has no migration
  # DSL form.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Only `down/0` removes columns, and only the ones `up/0` added.
  # excellent_migrations:safety-assured-for-this-file column_removed
  # One row per Telegram chat a user connects, so the table is small, and the
  # index has to exist before the release that looks tokens up by it serves a
  # request.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  def up do
    alter table(:telegram_integrations) do
      add(:link_token_hash, :string)
    end

    flush()

    execute("""
    UPDATE telegram_integrations
    SET link_token_hash = encode(sha256(convert_to(link_token, 'UTF8')), 'hex')
    WHERE link_token IS NOT NULL AND link_token_hash IS NULL
    """)

    create(
      unique_index(:telegram_integrations, [:link_token_hash],
        where: "link_token_hash IS NOT NULL"
      )
    )
  end

  def down do
    drop(unique_index(:telegram_integrations, [:link_token_hash]))

    alter table(:telegram_integrations) do
      remove(:link_token_hash)
    end
  end
end
