defmodule Tymeslot.Repo.Migrations.AddMeetingIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create_if_not_exists index(:meetings, [:uid], unique: true, concurrently: true)
    create_if_not_exists index(:meetings, [:status], concurrently: true)
    create_if_not_exists index(:meetings, [:start_time], concurrently: true)
    create_if_not_exists index(:meetings, [:end_time], concurrently: true)

    create_if_not_exists index(:meetings, [:organizer_email, :start_time],
      concurrently: true,
      name: :idx_meetings_organizer_email_start_time
    )

    create_if_not_exists index(:meetings, [:attendee_email, :start_time],
      concurrently: true,
      name: :idx_meetings_attendee_email_start_time
    )

    create_if_not_exists index(:meetings, [:start_time],
      where: "status = 'confirmed' AND reminder_email_sent = false",
      concurrently: true,
      name: :idx_meetings_reminders_due
    )
  end
end
