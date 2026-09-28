defmodule Tymeslot.Infrastructure.AdminAlerts.DigestEntryQueries do
  @moduledoc """
  Data access for `DigestEntrySchema`, the admin alerts waiting for the
  daily digest or the error roll-up.
  """

  import Ecto.Query

  alias Tymeslot.Infrastructure.AdminAlerts.DigestEntrySchema
  alias Tymeslot.Repo

  # Any constant unique to this lock among the application's advisory locks.
  @error_burst_lock_key 7_310_422_001

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
  Deletes every entry waiting in `batch` and returns them, oldest first.

  One statement, so an entry cannot be counted between being read and being
  deleted: a concurrent repeat either lands before the delete and is
  returned, or after it and starts a fresh entry for the next email. Run it
  inside the transaction that hands the entries on, so a failed hand-off
  rolls the delete back.
  """
  @spec take_all(String.t()) :: [DigestEntrySchema.t()]
  def take_all(batch) do
    {_count, entries} =
      Repo.delete_all(
        from(entry in DigestEntrySchema, where: entry.batch == ^batch, select: entry)
      )

    Enum.sort_by(entries, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
  end

  @doc "Deletes every entry waiting in `batch`, returning how many there were."
  @spec delete_all(String.t()) :: non_neg_integer()
  def delete_all(batch) do
    {count, _rows} =
      Repo.delete_all(from(entry in DigestEntrySchema, where: entry.batch == ^batch))

    count
  end

  @doc """
  Takes the transaction-scoped advisory lock that serialises the error alert
  burst decision across the cluster: counting the alerts already emailed and
  sending or holding the next one happen as one step. Released when the
  calling transaction ends; call it inside one.
  """
  @spec lock_error_burst() :: :ok
  def lock_error_burst do
    _result = Repo.query!("SELECT pg_advisory_xact_lock($1)", [@error_burst_lock_key])
    :ok
  end
end
