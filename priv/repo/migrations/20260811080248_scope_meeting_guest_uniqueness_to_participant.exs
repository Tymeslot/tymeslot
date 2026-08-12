defmodule Tymeslot.Repo.Migrations.ScopeMeetingGuestUniquenessToParticipant do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file operation_delete
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # The deduplication is deliberately raw SQL: it is a single set-based
  # statement whose correctness comes from the self-join, and expressing it
  # through Ecto would mean loading the table into the VM to do the same thing
  # slower.
  #
  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so there are no concurrent readers to lock
  # out and no writer racing the deduplication below. Revisit if a deployment
  # target ever migrates against a running instance.

  @moduledoc """
  Splits the `(meeting_id, email)` guest uniqueness into per-booker scopes.

  That index was written when a meeting had exactly one booker. A group slot
  is one shared meeting row with many bookers, so it made "someone else
  already invited this address" a hard failure of the second booking, with no
  way for the second booker to tell which guest was the problem.

  The rule each booker actually needs is "I cannot invite the same person
  twice", which is per participant. Solo bookings keep the original rule
  unchanged: their guests carry no `participant_id`, and NULLs are distinct in
  a Postgres unique index, so they need their own partial index to stay
  protected.

  Both new indexes are weaker than the one they replace — every row that
  satisfied the old index satisfies these — so the deduplication in `up/0`
  guards against a database that arrived here some other way (a restore, a
  hand-dropped index), not against anything this rename itself creates.
  """

  def up do
    # Both new indexes are strictly weaker than the one being dropped: each is
    # that same rule restricted to a subset of the table, so every row that
    # satisfied `(meeting_id, email)` satisfies these. Rather than assume that,
    # the migration deduplicates within each new scope first — a database that
    # somehow collected duplicates (a restore, a direct insert, an index
    # dropped by hand) is repaired instead of failing halfway.
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
  end
end
