defmodule Tymeslot.Repo.Migrations.AddMultiCalendarSupport do
  use Ecto.Migration

  def change do
    alter table(:calendar_integrations) do
      add :calendar_list, {:array, :map}, default: []
      add :default_booking_calendar_id, :string
    end

    # Create index for faster lookups
    create index(:calendar_integrations, [:default_booking_calendar_id])
  end
end