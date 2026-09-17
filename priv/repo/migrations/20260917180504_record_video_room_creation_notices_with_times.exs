defmodule Tymeslot.Repo.Migrations.RecordVideoRoomCreationNoticesWithTimes do
  use Ecto.Migration

  @moduledoc """
  Records *when* the owner was emailed about each room creation refusal,
  rather than only that they were.

  `room_creation_errors_notified` was a list of codes, which could only ever
  grow: a refusal fixed and met again a year later was never mentioned again,
  and a claim spent on an email that was then discarded was never given back.
  It also tied the stored data to the enum, so removing or renaming a code
  would have left values nothing reads.

  `room_creation_error_notices` replaces it with a map of code to the time
  that code was last emailed about. A code missing from the map, or one last
  emailed about long enough ago, may be emailed about again; a code nothing
  reads any more is simply an entry nothing looks up.

  The column it replaces was added on this branch and has never been part of
  a release, so nothing outside a development database can hold values worth
  carrying over.
  """

  # PostgreSQL 11+ stores a non-volatile default in the catalogue rather than
  # rewriting the table, so this is a metadata-only change. Migrations also run
  # offline here (`start.sh` runs them in a one-shot VM and only starts Phoenix
  # once they finish), so no live traffic waits on the lock either way.
  def change do
    alter table(:video_integrations) do
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add(:room_creation_error_notices, :map, null: false, default: %{})
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:room_creation_errors_notified, {:array, :string}, null: false, default: [])
    end
  end
end
