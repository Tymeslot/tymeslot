defmodule Tymeslot.Repo.Migrations.AddInvitationIdToMeetings do
  @moduledoc """
  Links a meeting to the invitation it was booked through.

  The partial unique index lets Postgres refuse a second live booking per
  invitation. Its status list must equal `Tymeslot.Meetings.MeetingState.occupying/0`
  (`Tymeslot.Meetings.InvitationOccupyingIndexTest` pins this). Cancelled,
  completed and expired meetings fall outside it, so an invitation can be
  booked again after a cancellation while its history is kept. A second,
  non-unique index serves the foreign key's nilify and every lookup of an
  invitation's meetings across all statuses; it is partial too, so it holds
  only linked meetings.

  Deleting an invitation (or its meeting type) nilifies the link; it never
  deletes meetings.

  `meetings` is the largest table, so both indexes are built concurrently and
  the migration cannot run in a transaction. The column is added only if
  missing, so a run after an interrupted one may meet links already written:
  any second live meeting on one invitation is unlinked (the earliest keeps
  it) before the unique index is built, and an invalid index left by an
  interrupted build is dropped before building again.
  """

  use Ecto.Migration

  # The deduplication is a single UPDATE over a column this migration adds,
  # outside a transaction because the indexes are built concurrently.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update
  # The foreign key is added to a new, all-NULL column, so validating it
  # scans nothing that can fail.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # `down/0` drops only the column `up/0` added.
  # excellent_migrations:safety-assured-for-this-file column_removed

  @disable_ddl_transaction true
  @disable_migration_lock true

  @occupying_index :meetings_invitation_id_occupying_index
  @lookup_index :meetings_invitation_id_index
  @occupying_statuses "('confirmed', 'pending', 'awaiting_payment', 'awaiting_approval')"

  def up do
    alter table(:meetings) do
      add_if_not_exists(
        :invitation_id,
        references(:meeting_type_invitations, on_delete: :nilify_all)
      )
    end

    drop_if_exists(index(:meetings, [:invitation_id], name: @lookup_index, concurrently: true))

    create(
      index(:meetings, [:invitation_id],
        name: @lookup_index,
        where: "invitation_id IS NOT NULL",
        concurrently: true
      )
    )

    execute("""
    UPDATE meetings SET invitation_id = NULL
    WHERE id IN (
      SELECT id FROM (
        SELECT id,
               ROW_NUMBER() OVER (PARTITION BY invitation_id ORDER BY inserted_at, id) AS rn
        FROM meetings
        WHERE invitation_id IS NOT NULL AND status IN #{@occupying_statuses}
      ) ranked
      WHERE rn > 1
    )
    """)

    drop_if_exists(
      index(:meetings, [:invitation_id], name: @occupying_index, concurrently: true)
    )

    create(
      unique_index(:meetings, [:invitation_id],
        name: @occupying_index,
        where: "invitation_id IS NOT NULL AND status IN #{@occupying_statuses}",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:meetings, [:invitation_id], name: @occupying_index, concurrently: true)
    )

    drop_if_exists(index(:meetings, [:invitation_id], name: @lookup_index, concurrently: true))

    alter table(:meetings) do
      remove_if_exists(:invitation_id, :id)
    end
  end
end
