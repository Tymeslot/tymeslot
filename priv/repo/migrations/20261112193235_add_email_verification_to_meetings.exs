defmodule Tymeslot.Repo.Migrations.AddEmailVerificationToMeetings do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Widening the status vocabulary: every row the old constraint admitted is
  # admitted by the new one, so validation cannot fail and nothing needs repair.
  # Migrations run offline (start.sh), so the brief lock blocks no traffic.
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
    # A row written as awaiting_verification would violate the narrower set:
    # expire it first, exactly as the domain's own expiry would.
    execute(
      "UPDATE meetings SET status = 'expired', cancelled_at = COALESCE(cancelled_at, NOW()) WHERE status = 'awaiting_verification'"
    )

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
