defmodule Tymeslot.Repo.Migrations.EncryptAndHashLinkTokens do
  @moduledoc """
  Stops storing four link tokens as themselves:

    * `polls.token`, the poll's public voting link;
    * `poll_participants.token`, a participant's personal `?p=` link;
    * `meeting_guests.rsvp_token`, a guest's RSVP links;
    * `profiles.freebusy_token`, the free/busy feed.

  Each is shown again after it is issued (the host copies the poll link or
  the feed URL from the dashboard, every guest email rebuilds the RSVP links,
  a participant registering again gets their link back), so a hash alone
  would not do. Each token is encrypted into `*_encrypted`, and its SHA-256
  goes into `*_hash`, which the lookups use and a unique index covers. The
  hash is computed as `Tymeslot.Security.Token.hash_token/1` computes it
  (lower-case hex), and distinct tokens hash to distinct values, so the index
  meets no duplicate.

  ## The plain columns stay for now

  An image can be rolled back without this migration's `down/0` running, and
  the previous release reads and looks up only the plain columns. They are
  therefore kept, with their values, and the application stops reading and
  writing them; the ones that were `NOT NULL` lose it so new rows can leave
  them empty. A later release, once rolling back past this one is no longer
  supported, empties and drops them.

  Encrypting needs the application's key, so the backfill calls
  `Tymeslot.Security.Encryption`, as earlier encryption backfills did. Both
  backfills only fill a column that is still empty, so running them again
  changes nothing.

  Rolling back copies each token back into its plain column where that is
  empty (rows created since), then drops the new columns.
  """

  use Ecto.Migration

  alias Tymeslot.Security.Encryption

  # Backfills computing values from another column, one of them with the
  # application's key; neither has a migration DSL form.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Only `down/0` removes columns, and only the ones `up/0` added.
  # excellent_migrations:safety-assured-for-this-file column_removed
  # The unique indexes have to exist before the release that looks tokens up
  # by their hash serves a request. Polls, their participants, guests and
  # profiles are small tables next to meetings.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  # {table, token column, primary key type}
  @tokens [
    {"polls", "token", "uuid"},
    {"poll_participants", "token", "uuid"},
    {"meeting_guests", "rsvp_token", "uuid"},
    {"profiles", "freebusy_token", "bigint"}
  ]

  @required ["polls", "poll_participants", "meeting_guests"]

  @batch_size 500

  def up do
    for {table, column, _id_type} <- @tokens do
      alter table(table) do
        add(:"#{column}_encrypted", :binary)
        add(:"#{column}_hash", :string)
      end
    end

    for {table, column, _id_type} <- @tokens, table in @required do
      execute("ALTER TABLE #{table} ALTER COLUMN #{column} DROP NOT NULL")
    end

    flush()

    for {table, column, _id_type} <- @tokens do
      execute("""
      UPDATE #{table}
      SET #{column}_hash = encode(sha256(convert_to(#{column}, 'UTF8')), 'hex')
      WHERE #{column} IS NOT NULL AND #{column}_hash IS NULL
      """)
    end

    execute(fn -> Enum.each(@tokens, &encrypt_column/1) end)

    for {table, column, _id_type} <- @tokens do
      create(unique_index(table, [:"#{column}_hash"]))
    end
  end

  def down do
    execute(fn -> Enum.each(@tokens, &restore_column/1) end)

    for {table, column, _id_type} <- @tokens do
      drop(unique_index(table, [:"#{column}_hash"]))

      alter table(table) do
        remove(:"#{column}_hash")
        remove(:"#{column}_encrypted")
      end
    end
  end

  defp encrypt_column({table, column, id_type}) do
    %{rows: rows} =
      repo().query!("""
      SELECT id, #{column} FROM #{table}
      WHERE #{column} IS NOT NULL AND #{column}_encrypted IS NULL
      ORDER BY id
      """)

    rows
    |> Enum.map(fn [id, token] -> [id, Encryption.encrypt(token)] end)
    |> write(table, "#{column}_encrypted", id_type, "bytea")
  end

  defp restore_column({table, column, id_type}) do
    %{rows: rows} =
      repo().query!("""
      SELECT id, #{column}_encrypted FROM #{table}
      WHERE #{column} IS NULL AND #{column}_encrypted IS NOT NULL
      ORDER BY id
      """)

    rows
    |> Enum.flat_map(fn [id, ciphertext] ->
      case Encryption.decrypt_with_status(ciphertext) do
        {:ok, token} when is_binary(token) -> [[id, token]]
        _unreadable -> []
      end
    end)
    |> write(table, column, id_type, "text")
  end

  defp write(rows, table, column, id_type, value_type) do
    rows
    |> Enum.chunk_every(@batch_size)
    |> Enum.each(fn batch ->
      [ids, values] = Enum.zip_with(batch, & &1)

      repo().query!(
        """
        UPDATE #{table} AS t SET #{column} = d.value
        FROM unnest($1::#{id_type}[], $2::#{value_type}[]) AS d(id, value)
        WHERE t.id = d.id
        """,
        [ids, values]
      )
    end)
  end
end
