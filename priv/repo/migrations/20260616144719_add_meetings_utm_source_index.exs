defmodule Tymeslot.Repo.Migrations.AddMeetingsUtmSourceIndex do
  use Ecto.Migration

  # Build the index without locking out booking writes to the populated
  # `meetings` table (see 20250914085000_add_meeting_indexes for the convention).
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Serves Tymeslot.Meetings.bookings_by_utm_source/3, which filters by
    # organizer_user_id (+ inserted_at range) and groups by a non-null
    # utm_source. The partial composite index matches that access path; the
    # previously-planned bare utm_campaign index was dropped — no query reads it.
    create_if_not_exists index(:meetings, [:organizer_user_id, :utm_source],
                           where: "utm_source IS NOT NULL",
                           concurrently: true,
                           name: :meetings_organizer_utm_source_index
                         )
  end
end
