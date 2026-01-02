defmodule Tymeslot.Repo.Migrations.AddQueryOptimizationIndexes do
  use Ecto.Migration

  def change do
    # Composite indexes for meetings table to optimize user meeting queries
    # These extend existing (email, status) indexes by adding start_time for better query performance
    create_if_not_exists index(:meetings, [:organizer_email, :status, :start_time], 
      name: :meetings_organizer_status_start_time_index)
    
    create_if_not_exists index(:meetings, [:attendee_email, :status, :start_time], 
      name: :meetings_attendee_status_start_time_index)

    # Composite index for calendar integrations to optimize provider lookups
    create_if_not_exists index(:calendar_integrations, [:user_id, :provider], 
      name: :calendar_integrations_user_provider_index)

    # Composite index for video integrations to optimize default/active lookups
    create_if_not_exists index(:video_integrations, [:user_id, :is_default, :is_active], 
      name: :video_integrations_user_default_active_index)

    # Composite index for availability breaks to optimize time-based queries
    create_if_not_exists index(:availability_breaks, [:weekly_availability_id, :start_time], 
      name: :availability_breaks_weekly_start_time_index)
  end
end