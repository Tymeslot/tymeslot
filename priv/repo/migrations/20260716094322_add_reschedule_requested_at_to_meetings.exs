defmodule Tymeslot.Repo.Migrations.AddRescheduleRequestedAtToMeetings do
  use Ecto.Migration

  @moduledoc """
  Splits the "organizer requested a new time" annotation out of `status`,
  which previously overloaded the lifecycle field: writing
  `status = "reschedule_requested"` destroyed whatever lifecycle status
  (pending, awaiting_payment, confirmed) the meeting held before the request,
  so nothing could restore it once the attendee rebooked.

  Existing rows still sitting in `status = "reschedule_requested"` are
  backfilled with a `reschedule_requested_at` timestamp (approximated by
  `updated_at`, the closest historical signal available) and their `status`
  reset to `"confirmed"`. This is a lossy repair, not a faithful replay: the
  old code never restored `status` once the attendee rebooked, so a row in
  this state may equally be a meeting that is genuinely still awaiting a new
  time, or one that was already rebooked under the old model (both looked
  identical on disk - a live provider event either way, no discriminator in
  the database). `"confirmed"` is used as the restored value because it is
  the dominant, unrecoverable case; rows that are in fact still awaiting a
  new time will simply keep behaving as such until the attendee rebooks
  again, at which point `reschedule_requested_at` is cleared as normal.

  `"reschedule_requested"` is intentionally left in the status enum: no code
  writes it after this change, so leaving the value costs nothing, and
  removing it risks breaking any straggler reads.
  """

  def up do
    alter table(:meetings) do
      add(:reschedule_requested_at, :utc_datetime)
    end

    execute("""
    UPDATE meetings
    SET reschedule_requested_at = updated_at,
        status = 'confirmed'
    WHERE status = 'reschedule_requested'
    """)
  end

  def down do
    execute("""
    UPDATE meetings
    SET status = 'reschedule_requested'
    WHERE reschedule_requested_at IS NOT NULL
      AND status IN ('confirmed', 'pending', 'awaiting_payment')
    """)

    alter table(:meetings) do
      remove(:reschedule_requested_at)
    end
  end
end
