defmodule Tymeslot.Security.CredentialReencryptionQueries do
  @moduledoc """
  Data access for the credential re-encryption sweep.

  Reads encrypted columns in keyset-paginated batches and writes migrated values
  back a row at a time. Schemaless queries keep the sweep decoupled from the
  individual integration schemas — it operates purely on table names and column
  lists supplied by `Tymeslot.Security.CredentialReencryption`.
  """

  import Ecto.Query

  alias Tymeslot.Repo

  @doc """
  Fetches up to `limit` rows of the given table with `id > after_id`, ordered by
  `id`, selecting only the id and the requested encrypted columns.
  """
  @spec fetch_batch(String.t(), [atom()], integer(), pos_integer()) :: [map()]
  def fetch_batch(table, columns, after_id, limit) do
    fields = [:id | columns]

    query =
      from(r in table,
        where: r.id > ^after_id,
        order_by: [asc: r.id],
        limit: ^limit,
        select: map(r, ^fields)
      )

    Repo.all(query)
  end

  @doc """
  Writes the given column updates for a single row, one column at a time,
  each guarded by a compare-and-swap against the ciphertext it was read with.

  `updates` is a list of `{column, old_ciphertext, new_ciphertext}` tuples. A
  column is only written when its current value still matches
  `old_ciphertext` — if a concurrent writer changed or deleted the row
  between the batch read and this call, that column's update affects zero
  rows and is silently skipped rather than clobbering the newer value.

  Returns `true` if at least one column was updated, `false` otherwise
  (including the no-op case of an empty `updates` list).
  """
  @spec update_row(String.t(), integer(), [{atom(), binary(), binary()}]) :: boolean()
  def update_row(_table, _id, []), do: false

  def update_row(table, id, updates) do
    Enum.reduce(updates, false, fn {column, old_value, new_value}, any_updated? ->
      query =
        from(r in table,
          where: r.id == ^id and field(r, ^column) == ^old_value
        )

      case Repo.update_all(query, set: [{column, new_value}]) do
        {0, _returned} -> any_updated?
        {_count, _returned} -> true
      end
    end)
  end
end
