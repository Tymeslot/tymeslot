defmodule Tymeslot.Repo.Migrations.AddUniqueLiveParticipantPerMeeting do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file operation_delete
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # The deduplication is deliberately raw SQL: one set-based statement whose
  # correctness comes from the self-join, rather than loading every
  # participant into the VM to do the same thing slower.
  #
  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so there are no concurrent readers to lock
  # out and no writer racing the deduplication below. Revisit if a deployment
  # target ever migrates against a running instance.

  @moduledoc """
  One live seat per email address per group meeting.

  A solo booking could not be taken twice: the partial unique index on
  `(organizer_user_id, start_time)` made the second attempt fail. Group seats
  had no equivalent, so submitting the booking form from two tabs consumed two
  seats, produced two management tokens, and listed the same person twice on
  the organiser's calendar event — with cancelling one seat freeing only half
  of what they took.

  Self-healing: any database that already collected duplicates is repaired
  first, keeping the earliest live seat for each `(meeting, email)` and
  cancelling the later ones. Cancelling rather than deleting is deliberate:
  `cancelled_at` is how a released seat is recorded everywhere else, it
  returns the seat to the pool the same way, and it leaves the booking
  visible rather than vanishing it.
  """

  def up do
    execute("""
    UPDATE meeting_participants AS later
    SET cancelled_at = COALESCE(later.cancelled_at, NOW())
    FROM meeting_participants AS keep
    WHERE keep.meeting_id = later.meeting_id
      AND lower(keep.email) = lower(later.email)
      AND keep.cancelled_at IS NULL
      AND later.cancelled_at IS NULL
      AND (keep.inserted_at, keep.id) < (later.inserted_at, later.id)
    """)

    create unique_index(:meeting_participants, ["meeting_id", "lower(email)"],
             where: "cancelled_at IS NULL",
             name: :meeting_participants_live_email_index
           )
  end

  def down do
    drop_if_exists index(:meeting_participants, ["meeting_id", "lower(email)"],
                     name: :meeting_participants_live_email_index
                   )
  end
end
