defmodule Tymeslot.Repo.Migrations.AddUserMeetingLookupIndexes do
  use Ecto.Migration

  def change do
    # Index for organizer email lookups
    # Used by: list_*_meetings_for_user functions when filtering by organizer_email
    create_if_not_exists index(:meetings, [:organizer_email])

    # Index for attendee email lookups  
    # Used by: list_*_meetings_for_user functions when filtering by attendee_email
    create_if_not_exists index(:meetings, [:attendee_email])

    # Composite index for organizer email with time-based filtering
    # Used by: list_upcoming_meetings_for_user, list_past_meetings_for_user
    create_if_not_exists index(:meetings, [:organizer_email, :start_time])
    create_if_not_exists index(:meetings, [:organizer_email, :end_time])

    # Composite index for attendee email with time-based filtering
    # Used by: list_upcoming_meetings_for_user, list_past_meetings_for_user  
    create_if_not_exists index(:meetings, [:attendee_email, :start_time])
    create_if_not_exists index(:meetings, [:attendee_email, :end_time])

    # Composite index for organizer email with status filtering
    # Used by: list_cancelled_meetings_for_user and future status-based queries
    create_if_not_exists index(:meetings, [:organizer_email, :status])

    # Composite index for attendee email with status filtering
    # Used by: list_cancelled_meetings_for_user and future status-based queries
    create_if_not_exists index(:meetings, [:attendee_email, :status])

    # Composite index for user integrations (already exist but documenting usage)
    # Note: These should already exist from the schema definitions, but adding if missing

    # For calendar integrations count queries
    create_if_not_exists index(:calendar_integrations, [:user_id])

    # For video integrations count queries  
    create_if_not_exists index(:video_integrations, [:user_id])

    # For meeting types count queries
    create_if_not_exists index(:meeting_types, [:user_id])

    # For meeting types active filtering
    create_if_not_exists index(:meeting_types, [:user_id, :is_active])

    # For profile username lookups (optimized context resolution)
    create_if_not_exists index(:profiles, [:username])
  end
end