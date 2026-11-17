defmodule Tymeslot.Repo.Migrations.AddEmailVerificationToMeetings do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file column_removed
  # Widening the status vocabulary: every row the old constraint admitted is
  # admitted by the new one, so validation cannot fail and nothing needs repair.
  # Railway migrates in the new container while the old one still serves, so
  # `up/0` runs outside a DDL transaction: the widened check is added
  # `NOT VALID` under a temporary name (a brief lock, no scan), validated
  # (a scan that lets reads and writes through), and only then swapped in for
  # the old one. The old check stays in force until the new one holds, and
  # every step is idempotent, so a run interrupted part-way can be re-run.
  # The only columns removed are this migration's own, in `down/0`, and the
  # only raw SQL besides the constraints is the swap and `down/0`'s delete of
  # bookings that were never verified (see there).
  @disable_ddl_transaction true

  @known_before "'pending', 'awaiting_payment', 'awaiting_approval', 'confirmed', 'cancelled', 'completed', 'expired', 'reschedule_requested'"
  @known_after @known_before <> ", 'awaiting_verification'"

  def up do
    # Both NULL means "never gated", which is true of every existing row.
    alter table(:meetings) do
      add_if_not_exists(:verification_deadline_at, :utc_datetime)
      add_if_not_exists(:email_verified_at, :utc_datetime)
    end

    drop_if_exists(constraint(:meetings, :meetings_status_must_be_known_widened))

    create(
      constraint(:meetings, :meetings_status_must_be_known_widened,
        check: "status IN (#{@known_after})",
        validate: false
      )
    )

    execute("ALTER TABLE meetings VALIDATE CONSTRAINT meetings_status_must_be_known_widened")
    drop_if_exists(constraint(:meetings, :meetings_status_must_be_known))

    execute("""
    ALTER TABLE meetings RENAME CONSTRAINT meetings_status_must_be_known_widened
      TO meetings_status_must_be_known
    """)
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
