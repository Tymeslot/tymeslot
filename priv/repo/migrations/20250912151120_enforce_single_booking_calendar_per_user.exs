defmodule Tymeslot.Repo.Migrations.EnforceSingleBookingCalendarPerUser do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Ensure at most one integration per user has a non-null default_booking_calendar_id
    create_if_not_exists index(
             :calendar_integrations,
             [:user_id],
             where: "default_booking_calendar_id IS NOT NULL",
             name: :unique_booking_calendar_per_user,
             concurrently: true,
             unique: true
           )
  end
end
