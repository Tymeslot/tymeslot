defmodule Tymeslot.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  def change do
    # Composite indexes that will improve query performance
    # Only adding indexes that don't already exist

    # Composite index for finding meetings by status and time
    # Used by: list_meetings_by_status, list_upcoming_meetings
    # Improves queries that filter by both status AND start_time
    create index(:meetings, [:status, :start_time])

    # Index for email tracking queries
    # Used by: email workers checking if emails have been sent
    create index(:meetings, [:attendee_email_sent, :organizer_email_sent])

    # Index for reminder queries
    # Used by: list_meetings_needing_reminders
    create index(:meetings, [:reminder_email_sent, :start_time])

    # Composite index for time conflict checking
    # Used by: has_time_conflict? - checks overlapping meetings
    create index(:meetings, [:start_time, :end_time, :status])

    # Composite index for date range queries
    # Used by: list_meetings_by_date_range
    create index(:meetings, [:start_time, :end_time])

    # Partial index for finding meetings that need video rooms
    # Used by: video room worker to find confirmed meetings without video rooms
    create index(:meetings, [:status, :video_room_id],
      where: "status = 'confirmed' AND video_room_id IS NULL",
      name: :meetings_need_video_room_index
    )
  end
end
