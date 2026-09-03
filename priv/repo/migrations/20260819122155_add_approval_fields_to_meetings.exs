defmodule Tymeslot.Repo.Migrations.AddApprovalFieldsToMeetings do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # Both indexes are partial on `status = 'awaiting_approval'`, a status no row
  # can hold until this feature ships, so each one is built over an empty
  # subset. Tymeslot also migrates with the app stopped.

  # The approval clock. Every column is nullable and every existing row is
  # already correct with all of them nil: a meeting that never entered the
  # approval gate has no request time, no deadline and no resolution.
  #
  # `approval_deadline_at` is denormalised rather than recomputed from the
  # meeting type because the sweep queries it directly, and because the meeting
  # type's window may be edited — or the type archived — while a request is
  # still outstanding. The deadline promised to the invitee must not move.
  def change do
    alter table(:meetings) do
      add(:approval_requested_at, :utc_datetime)
      add(:approval_deadline_at, :utc_datetime)
      add(:approval_resolved_at, :utc_datetime)
      add(:approval_nudge_sent_at, :utc_datetime)
      add(:decline_reason, :string)
    end

    # Drives the expiry sweep: "held requests whose deadline has passed".
    create(
      index(:meetings, [:approval_deadline_at],
        where: "status = 'awaiting_approval'",
        name: :meetings_pending_approval_deadline
      )
    )

    # Drives the awaiting-approval count badge. The dashboard's
    # awaiting-approval section itself is keyed by email, not
    # organizer_user_id, and is served by the pre-existing
    # (organizer_email, status) / (attendee_email, status) indexes.
    create(
      index(:meetings, [:organizer_user_id],
        where: "status = 'awaiting_approval'",
        name: :meetings_pending_approval_by_organizer
      )
    )
  end
end
