defmodule Tymeslot.Repo.Migrations.AddConfirmedMeetingIdIndexToPolls do
  @moduledoc """
  Indexes the meeting a poll was confirmed into. The dashboard's meetings
  list preloads each meeting's confirming poll by this column, and the
  foreign key's nilify on meeting deletion searches it too; without an index
  both scan every poll.

  The index is partial, holding only confirmed polls, and not unique: nothing
  has ever stopped two polls naming one meeting, and refusing such rows here
  would mean rewriting a host's polls to build an index. It is built
  concurrently, so the migration cannot run in a transaction, and an invalid
  index left by an interrupted build is dropped before building again.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name :polls_confirmed_meeting_id_index

  def up do
    drop_if_exists(index(:polls, [:confirmed_meeting_id], name: @name, concurrently: true))

    create(
      index(:polls, [:confirmed_meeting_id],
        name: @name,
        where: "confirmed_meeting_id IS NOT NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(index(:polls, [:confirmed_meeting_id], name: @name, concurrently: true))
  end
end
