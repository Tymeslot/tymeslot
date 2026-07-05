defmodule Tymeslot.Security.CredentialReencryption do
  @moduledoc """
  One-time sweep that re-encrypts stored credentials under the current primary
  key (see `Tymeslot.Security.Encryption`).

  Walks every encrypted column across the integration tables, decrypts each value
  under whichever key its version prefix indicates, and rewrites it with the
  current primary key. The sweep is:

    * **idempotent / resumable** — values already at the current version are left
      untouched, so a re-run (or a run after a crash) is a no-op for migrated data;
    * **batched** — rows are read in keyset-paginated chunks rather than loading a
      whole table into memory;
    * **verifiable** — it returns per-table and total counts so an operator can
      confirm the sweep is complete (re-run until `migrated_values` is zero) before
      retiring the legacy key.

  Values that cannot be decrypted under any available key (corrupt, tampered, or
  encrypted under a key that is genuinely gone) are counted as `unrecoverable` and
  left as-is — they continue to flow through the normal `needs_reauth` path.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Security.CredentialReencryptionQueries, as: Queries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Slack
  alias Tymeslot.Telegram
  alias Tymeslot.Webhooks

  @default_batch_size 200

  # The context modules that own at-rest secrets. Each implements
  # `Tymeslot.Security.EncryptedStorage`, so the sweep discovers a domain's
  # table and encrypted columns through its public boundary rather than
  # reaching into its schema — a domain gaining a new `*_encrypted` field is
  # picked up automatically as long as its schema's
  # `encrypted_credential_fields/0` stays authoritative.
  @contexts [
    Calendar,
    Video,
    Slack,
    Telegram,
    Webhooks
  ]

  @type stats :: %{
          migrated_values: non_neg_integer(),
          migrated_rows: non_neg_integer(),
          already_current: non_neg_integer(),
          unrecoverable: non_neg_integer()
        }

  @doc """
  Runs the sweep across all integration tables.

  Options:

    * `:batch_size` — rows fetched per keyset page (default `#{@default_batch_size}`).

  Returns `{:ok, %{tables: %{table => stats}, totals: stats}}`, or an error tuple:

    * `{:error, :not_configured}` — no `DATA_ENCRYPTION_KEY` is set, so there is
      no primary key to migrate to; configure one first.
    * `{:error, {:invalid_batch_size, value}}` — `:batch_size` was not a
      positive integer. A batch size of `0` or less would silently report an
      empty (falsely "complete") sweep, or raise in Postgres, so it is rejected
      up front instead.
  """
  @spec run(keyword()) ::
          {:ok, %{tables: %{String.t() => stats}, totals: stats}}
          | {:error, :not_configured}
          | {:error, {:invalid_batch_size, term()}}
  def run(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    with :ok <- check_configured(),
         :ok <- check_batch_size(batch_size) do
      tables =
        Map.new(covered_tables(), fn {table, columns} ->
          {table, sweep_table(table, columns, batch_size)}
        end)

      {:ok, %{tables: tables, totals: total_stats(tables)}}
    end
  end

  defp check_configured do
    if Encryption.current_version() == 0, do: {:error, :not_configured}, else: :ok
  end

  defp check_batch_size(size) when is_integer(size) and size >= 1, do: :ok
  defp check_batch_size(size), do: {:error, {:invalid_batch_size, size}}

  @doc "The tables and encrypted columns the sweep covers."
  @spec covered_tables() :: [{String.t(), [atom()]}]
  def covered_tables do
    Enum.map(@contexts, & &1.encrypted_storage())
  end

  defp sweep_table(table, columns, batch_size) do
    sweep_batches(table, columns, batch_size, 0, empty_stats())
  end

  defp sweep_batches(table, columns, batch_size, after_id, stats) do
    case Queries.fetch_batch(table, columns, after_id, batch_size) do
      [] ->
        stats

      rows ->
        stats = Enum.reduce(rows, stats, &sweep_row(table, columns, &1, &2))
        last_id = rows |> List.last() |> Map.fetch!(:id)
        sweep_batches(table, columns, batch_size, last_id, stats)
    end
  end

  defp sweep_row(table, columns, row, stats) do
    {updates, stats} =
      Enum.reduce(columns, {[], stats}, fn column, {updates, acc} ->
        old_value = Map.get(row, column)

        case reencrypt_value(old_value) do
          :skip ->
            {updates, acc}

          :already_current ->
            {updates, bump(acc, :already_current)}

          :unrecoverable ->
            {updates, bump(acc, :unrecoverable)}

          {:migrated, value} ->
            {[{column, old_value, value} | updates], bump(acc, :migrated_values)}
        end
      end)

    if updates == [] do
      stats
    else
      # Each column is written with a compare-and-swap against the ciphertext
      # read in this batch, so a concurrent writer (e.g. an OAuth token
      # refresh) landing between the fetch and this write is never clobbered —
      # that column's CAS simply matches zero rows and is skipped.
      if Queries.update_row(table, Map.fetch!(row, :id), updates) do
        bump(stats, :migrated_rows)
      else
        stats
      end
    end
  end

  defp reencrypt_value(nil), do: :skip

  defp reencrypt_value(value) when is_binary(value) do
    if Encryption.current?(value) do
      :already_current
    else
      case Encryption.decrypt_with_status(value) do
        # Too short to be real ciphertext — leave untouched.
        {:ok, nil} -> :skip
        {:ok, plaintext} -> {:migrated, Encryption.encrypt(plaintext)}
        {:error, :requires_reencryption} -> :unrecoverable
      end
    end
  end

  defp empty_stats do
    %{migrated_values: 0, migrated_rows: 0, already_current: 0, unrecoverable: 0}
  end

  defp bump(stats, key), do: Map.update!(stats, key, &(&1 + 1))

  defp total_stats(tables) do
    Enum.reduce(Map.values(tables), empty_stats(), fn stats, acc ->
      Map.merge(acc, stats, fn _key, a, b -> a + b end)
    end)
  end
end
