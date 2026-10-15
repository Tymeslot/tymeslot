defmodule Tymeslot.Repo.Migrations.ScopeMeetingGuestsToParticipants do
  @moduledoc """
  Ties a guest to the group-meeting participant who invited them, and splits
  the `(meeting_id, email)` guest uniqueness into per-booker scopes.

  That index was written when a meeting had exactly one booker. A group slot
  is one shared meeting row with many bookers, so it would make "someone else
  already invited this address" a hard failure of the second booking, with no
  way for the second booker to tell which guest was the problem.

  The rule each booker actually needs is "I cannot invite the same person
  twice", which is per participant. One-to-one bookings keep the original rule
  unchanged: their guests carry no `participant_id`, and NULLs are distinct in
  a Postgres unique index, so they need their own partial index to stay
  protected.

  Both new indexes are weaker than the one they replace, so every row that
  satisfied the old index satisfies them. The deduplication in `up/0` guards
  against a database that arrived here some other way (a restore, a
  hand-dropped index), repairing it rather than failing halfway.
  """

  use Ecto.Migration

  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so no request waits on these locks and no
  # writer races the deduplication. Revisit if a deployment target ever
  # migrates against a running instance.
  #
  # The deduplication is a single set-based statement whose correctness comes
  # from the self-join; through Ecto it would mean loading the table into the
  # VM to do the same thing slower.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # Building the indexes concurrently would need `@disable_ddl_transaction`,
  # and a failed concurrent build leaves an INVALID index behind for a
  # self-hoster to find and drop by hand: strictly worse than a brief lock
  # during an offline migration on a table far smaller than meetings.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  #
  # `down/0` removes only the column `up/0` added.
  # excellent_migrations:safety-assured-for-this-file column_removed

  def up do
    alter table(:meeting_guests) do
      # The column is added in this same statement, so every existing row is
      # NULL and the foreign key has nothing to validate.
      # excellent_migrations:safety-assured-for-next-line column_reference_added
      add :participant_id,
          references(:meeting_participants, type: :binary_id, on_delete: :delete_all)
    end

    create index(:meeting_guests, [:participant_id])

    # Keep the oldest guest in each new scope and drop the later duplicates.
    execute("""
    DELETE FROM meeting_guests g
    USING meeting_guests keep
    WHERE g.meeting_id = keep.meeting_id
      AND g.email = keep.email
      AND g.participant_id IS NOT DISTINCT FROM keep.participant_id
      AND (keep.inserted_at, keep.id) < (g.inserted_at, g.id)
    """)

    drop_if_exists unique_index(:meeting_guests, [:meeting_id, :email])

    create unique_index(:meeting_guests, [:meeting_id, :email],
             where: "participant_id IS NULL",
             name: :meeting_guests_meeting_id_email_solo_index
           )

    create unique_index(:meeting_guests, [:meeting_id, :participant_id, :email],
             where: "participant_id IS NOT NULL",
             name: :meeting_guests_participant_id_email_index
           )
  end

  def down do
    drop_if_exists index(:meeting_guests, [:meeting_id, :participant_id, :email],
                     name: :meeting_guests_participant_id_email_index
                   )

    drop_if_exists index(:meeting_guests, [:meeting_id, :email],
                     name: :meeting_guests_meeting_id_email_solo_index
                   )

    # Rolling back re-imposes the stricter rule, so the rows a group slot was
    # allowed to hold have to go first: keep the oldest guest per
    # (meeting, email) and drop the later duplicates.
    execute("""
    DELETE FROM meeting_guests g
    USING meeting_guests keep
    WHERE g.meeting_id = keep.meeting_id
      AND g.email = keep.email
      AND (keep.inserted_at, keep.id) < (g.inserted_at, g.id)
    """)

    create unique_index(:meeting_guests, [:meeting_id, :email])

    drop_if_exists index(:meeting_guests, [:participant_id])

    alter table(:meeting_guests) do
      remove :participant_id
    end
  end
end
