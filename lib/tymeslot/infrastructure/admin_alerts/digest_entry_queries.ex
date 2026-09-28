defmodule Tymeslot.Infrastructure.AdminAlerts.DigestEntryQueries do
  @moduledoc """
  Data access for `DigestEntrySchema`, the info alerts waiting for the daily
  digest.
  """

  import Ecto.Query

  alias Tymeslot.Infrastructure.AdminAlerts.DigestEntrySchema
  alias Tymeslot.Repo

  @doc """
  Inserts an entry, or, when one with the same `alert_hash` is already
  waiting, counts the repeat on it and refreshes its message and metadata
  to the latest.
  """
  @spec upsert(map()) :: {:ok, DigestEntrySchema.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    now = DateTime.utc_now()

    %DigestEntrySchema{}
    |> DigestEntrySchema.changeset(attrs)
    |> Repo.insert(
      on_conflict: [
        inc: [occurrences: 1],
        set: [message: attrs.message, metadata: attrs.metadata, updated_at: now]
      ],
      conflict_target: :alert_hash
    )
  end

  @doc """
  Deletes every waiting entry and returns them, oldest first.

  One statement, so an entry cannot be counted between being read and being
  deleted: a concurrent repeat either lands before the delete and is
  returned, or after it and starts a fresh entry for the next digest. Run it
  inside the transaction that hands the entries on, so a failed hand-off
  rolls the delete back.
  """
  @spec take_all() :: [DigestEntrySchema.t()]
  def take_all do
    {_count, entries} = Repo.delete_all(from(entry in DigestEntrySchema, select: entry))
    Enum.sort_by(entries, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
  end

  @doc "Deletes every waiting entry, returning how many there were."
  @spec delete_all() :: non_neg_integer()
  def delete_all do
    {count, _rows} = Repo.delete_all(DigestEntrySchema)
    count
  end
end
