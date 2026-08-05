defmodule Tymeslot.Repo.Migrations.AddParticipantIdToMeetingGuests do
  use Ecto.Migration

  # Unlike the sibling migrations, this one touches an existing, populated
  # table, so each annotation below carries its own justification rather than
  # leaning on "the table is new".
  #
  # Migrations run offline either way: `start.sh` executes them in a one-shot
  # VM and only starts Phoenix once they finish, so no request is waiting on
  # these locks. Revisit this if a deployment target ever migrates against a
  # running instance.
  def change do
    alter table(:meeting_guests) do
      # The column is added in this same statement, so every existing row is
      # NULL and the foreign key has nothing to validate.
      # excellent_migrations:safety-assured-for-next-line column_reference_added
      add :participant_id,
          references(:meeting_participants, type: :binary_id, on_delete: :delete_all)
    end

    # Indexes the all-NULL column added just above. Building it concurrently
    # would need `@disable_ddl_transaction`, and a failed concurrent build
    # leaves an INVALID index behind for a self-hoster to find and drop by
    # hand — strictly worse than a brief lock during an offline migration.
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create index(:meeting_guests, [:participant_id])
  end
end
