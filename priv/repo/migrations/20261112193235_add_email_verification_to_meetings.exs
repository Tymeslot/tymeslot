defmodule Tymeslot.Repo.Migrations.AddEmailVerificationToMeetings do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file column_removed
  # Widening the status vocabulary: every row the old constraint admitted is
  # admitted by the new one, so validation cannot fail and nothing needs repair.
  # Migrations run offline (start.sh), so the brief lock blocks no traffic.
  # The only columns removed are this migration's own, in `down/0`, and the
  # only raw SQL besides the constraints is `down/0`'s delete of bookings
  # that were never verified (see there).
  @known_before "'pending', 'awaiting_payment', 'awaiting_approval', 'confirmed', 'cancelled', 'completed', 'expired', 'reschedule_requested'"
  @known_after @known_before <> ", 'awaiting_verification'"

  def up do
    # Both NULL means "never gated", which is true of every existing row.
    alter table(:meetings) do
      add(:verification_deadline_at, :utc_datetime)
      add(:email_verified_at, :utc_datetime)
    end

    drop_if_exists(constraint(:meetings, :meetings_status_must_be_known))

    create(
      constraint(:meetings, :meetings_status_must_be_known,
        check: "status IN (#{@known_after})"
      )
    )
  end

  def down do
    # Delete every booking that never left the gate verified, in any status:
    # held, expired or disowned. Once the columns are gone the old code cannot
    # tell them apart from bookings the organiser saw, and would show the
    # organiser bookings that were never confirmed. This is what
    # `EmailVerification.prune_unverified/1` does a day later in any case.
    # Their guests and participants cascade; payments and polls nilify.
    # Verified bookings stay. A held row with no deadline cannot be written,
    # but would violate the narrower status set, so it goes too.
    execute("""
    DELETE FROM meetings
    WHERE email_verified_at IS NULL
      AND (verification_deadline_at IS NOT NULL OR status = 'awaiting_verification')
    """)

    drop(constraint(:meetings, :meetings_status_must_be_known))

    create(
      constraint(:meetings, :meetings_status_must_be_known,
        check: "status IN (#{@known_before})"
      )
    )

    alter table(:meetings) do
      remove(:email_verified_at)
      remove(:verification_deadline_at)
    end
  end
end
