defmodule Tymeslot.Repo.Migrations.DropPlainCopiesOfEncryptedSecrets do
  @moduledoc """
  Drops the plain-text copies of secrets and link tokens that three earlier
  migrations moved into encrypted or hashed columns:

    * `20261002051404_encrypt_integration_secrets_at_rest`: `webhooks.url`,
      `video_integrations.custom_meeting_url`,
      `calendar_integrations.google_channel_secret` and `graph_client_state`;
    * `20261002052430_hash_telegram_link_tokens`: `telegram_integrations.link_token`;
    * `20261002052859_encrypt_and_hash_link_tokens`: `polls.token`,
      `poll_participants.token`, `meeting_guests.rsvp_token` and
      `profiles.freebusy_token`.

  This is the contract half of those expand migrations. They kept the plain
  columns, value and all, so that an image rolled back across them could
  still read every row; the release after them has shipped, and rolling back
  that far is no longer supported. From this release on, going back to a
  version before the encryption release needs a database restore.

  ## Rows a rolled-back image wrote

  Before anything is dropped, every row whose plain column holds a value that
  its encrypted column does not is re-encrypted from the plain value, and a
  token's lookup hash is recomputed from it too. The plain value is the
  current one in every such row. The current application never writes a
  plain column except to empty it: whenever an encrypted value changes, the
  same write clears its plain copy, and the poll, participant and RSVP
  tokens never change once issued. So a plain value that is missing from its
  encrypted column, differs from it, or sits beside one no configured key
  opens can only have been written by an image rolled back across the expand
  migrations, which wrote nothing but the plain column. A row whose two
  copies agree is left as it is.

  Telegram link tokens are dropped as they are. The current application
  issues and consumes them through the hash alone, they expire after ten
  minutes, and the user can issue a new one from the dashboard.

  The plain columns are emptied before they are dropped, so that the old
  values do not linger in the dropped column's storage until the table is
  next rewritten. The old unique indexes on the token columns go with them.

  Encrypting needs the application's key, so the backfill calls
  `Tymeslot.Security.Encryption`, as the expand migrations did. It logs one
  count per column (rows re-encrypted, and how many of those had an
  encrypted value no key opens) and the number of Telegram tokens dropped,
  never a value.

  ## Rolling back

  `down/0` adds the columns back, refills each from its encrypted column,
  and recreates the unique indexes on the token columns. A value no key opens
  leaves its column empty, as do the Telegram tokens, which only exist as
  hashes. The columns come back as `text`, so a value set since the upgrade
  that is longer than the old `varchar(255)` still fits.
  """

  use Ecto.Migration

  require Logger

  alias Tymeslot.Security.Encryption

  # The backfill re-encrypts values only the application can encrypt, and
  # emptying a column before dropping it has no DSL form.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # The columns have been unread since the encryption release, which is no
  # longer a supported rollback target. Where migrations run before the new
  # image serves (start.sh runs them in a one-shot VM before Phoenix starts),
  # nothing touches the columns while they go. A deployment that keeps the
  # previous image serving while the new one starts (Railway's zero-downtime
  # overlap) is different: that image never selects these columns (its
  # fields are `load_in_query: false`), so its reads are safe, but it writes
  # NULL to a plain column whenever a changeset sets or changes its
  # encrypted twin, so creating or changing a webhook URL, a free/busy
  # token, a custom video link or a calendar push secret fails with "column
  # does not exist" until the old image stops. That window is short and the
  # user can retry; it is accepted rather than spread over another release.
  # excellent_migrations:safety-assured-for-this-file column_removed
  # Only `down/0` creates indexes, recreating the ones `up/0` dropped on small
  # tables, before the release that looks tokens up by them serves a request.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  # {table, plain column, primary key type, lookup hash column or nil}
  @encrypted [
    {"webhooks", "url", "bigint", nil},
    {"video_integrations", "custom_meeting_url", "bigint", nil},
    {"calendar_integrations", "google_channel_secret", "bigint", nil},
    {"calendar_integrations", "graph_client_state", "bigint", nil},
    {"polls", "token", "uuid", "token_hash"},
    {"poll_participants", "token", "uuid", "token_hash"},
    {"meeting_guests", "rsvp_token", "uuid", "rsvp_token_hash"},
    {"profiles", "freebusy_token", "bigint", "freebusy_token_hash"}
  ]

  # {table, column} for the unique indexes the plain token columns carried;
  # Telegram's is partial, so `down/0` recreates it on its own.
  @unique_indexes [
    {"polls", "token"},
    {"poll_participants", "token"},
    {"meeting_guests", "rsvp_token"},
    {"profiles", "freebusy_token"},
    {"telegram_integrations", "link_token"}
  ]

  @plain_columns Enum.map(@encrypted, fn {table, column, _id, _hash} -> {table, column} end) ++
                   [{"telegram_integrations", "link_token"}]

  @page_size 1_000

  def up do
    execute(fn ->
      Enum.each(@encrypted, &heal_column/1)
      log_telegram_tokens_dropped()
    end)

    for {table, column} <- @unique_indexes do
      drop_if_exists(unique_index(table, [String.to_atom(column)]))
    end

    for {table, column} <- @plain_columns do
      execute("UPDATE #{table} SET #{column} = NULL WHERE #{column} IS NOT NULL")
    end

    for {table, column} <- @plain_columns do
      alter table(table) do
        remove_if_exists(String.to_atom(column), :text)
      end
    end
  end

  def down do
    for {table, column} <- @plain_columns do
      alter table(table) do
        add_if_not_exists(String.to_atom(column), :text)
      end
    end

    flush()

    execute(fn -> Enum.each(@encrypted, &restore_column/1) end)

    for {table, column} <- @unique_indexes, table != "telegram_integrations" do
      create_if_not_exists(unique_index(table, [String.to_atom(column)]))
    end

    create_if_not_exists(
      unique_index(:telegram_integrations, [:link_token], where: "link_token IS NOT NULL")
    )
  end

  defp heal_column({table, column, id_type, hash_column}) do
    {healed, healed_unreadable} =
      reduce_pages(
        {table, id_type},
        "#{column}, #{column}_encrypted",
        "#{column} IS NOT NULL AND #{column} <> ''",
        {0, 0},
        fn rows, {healed, healed_unreadable} ->
          stale =
            for [id, plain, ciphertext] <- rows,
                (state = compare(plain, ciphertext)) != :matching,
                do: {state, id, plain}

          stale
          |> Enum.map(fn {_state, id, plain} -> [id, Encryption.encrypt(plain)] end)
          |> write_encrypted(table, column, id_type, hash_column)

          {healed + length(stale),
           healed_unreadable + Enum.count(stale, &match?({:unreadable, _id, _plain}, &1))}
        end
      )

    Logger.info("Re-encrypted plain-only secrets before dropping their plain column",
      column: "#{table}.#{column}",
      healed: healed,
      healed_unreadable: healed_unreadable
    )
  end

  defp compare(_plain, nil), do: :plain_only

  defp compare(plain, ciphertext) do
    case Encryption.decrypt_with_status(ciphertext) do
      {:ok, ^plain} -> :matching
      {:ok, nil} -> :plain_only
      {:ok, _other} -> :differing
      {:error, :requires_reencryption} -> :unreadable
    end
  end

  # The hash is computed from the plain column of the same row, exactly as
  # the expand migration computed it (lower-case hex SHA-256, the format of
  # `Tymeslot.Security.Token.hash_token/1`).
  defp write_encrypted([], _table, _column, _id_type, _hash_column), do: :ok

  defp write_encrypted(rows, table, column, id_type, hash_column) do
    set_hash =
      if hash_column,
        do: ", #{hash_column} = encode(sha256(convert_to(t.#{column}, 'UTF8')), 'hex')",
        else: ""

    [ids, values] = Enum.zip_with(rows, & &1)

    repo().query!(
      """
      UPDATE #{table} AS t SET #{column}_encrypted = d.value#{set_hash}
      FROM unnest($1::#{id_type}[], $2::bytea[]) AS d(id, value)
      WHERE t.id = d.id
      """,
      [ids, values]
    )
  end

  # Folds `fun` over the rows matching `where`, one page of up to
  # @page_size rows at a time in primary-key order, so memory stays bounded
  # however large the table is. Each row comes back as [id | columns].
  defp reduce_pages({table, id_type} = source, columns, where, acc, fun, after_id \\ nil) do
    %{rows: rows} =
      repo().query!(
        """
        SELECT id, #{columns} FROM #{table}
        WHERE #{where} AND ($1::#{id_type} IS NULL OR id > $1::#{id_type})
        ORDER BY id
        LIMIT #{@page_size}
        """,
        [after_id]
      )

    case rows do
      [] ->
        acc

      rows ->
        reduce_pages(source, columns, where, fun.(rows, acc), fun, rows |> List.last() |> hd())
    end
  end

  defp log_telegram_tokens_dropped do
    %{rows: [[count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM telegram_integrations WHERE link_token IS NOT NULL AND link_token <> ''"
      )

    Logger.info("Dropping plain Telegram link tokens, which expire on their own",
      column: "telegram_integrations.link_token",
      dropped: count
    )
  end

  defp restore_column({table, column, id_type, _hash_column}) do
    reduce_pages(
      {table, id_type},
      "#{column}_encrypted",
      "#{column}_encrypted IS NOT NULL",
      :ok,
      fn rows, :ok ->
        rows
        |> Enum.flat_map(fn [id, ciphertext] ->
          case Encryption.decrypt_with_status(ciphertext) do
            {:ok, value} when is_binary(value) -> [[id, value]]
            _unreadable -> []
          end
        end)
        |> write_restored(table, column, id_type)
      end
    )
  end

  defp write_restored([], _table, _column, _id_type), do: :ok

  defp write_restored(rows, table, column, id_type) do
    [ids, values] = Enum.zip_with(rows, & &1)

    repo().query!(
      """
      UPDATE #{table} AS t SET #{column} = d.value
      FROM unnest($1::#{id_type}[], $2::text[]) AS d(id, value)
      WHERE t.id = d.id
      """,
      [ids, values]
    )

    :ok
  end
end
