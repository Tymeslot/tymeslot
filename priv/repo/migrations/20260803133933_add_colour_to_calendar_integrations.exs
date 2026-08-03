defmodule Tymeslot.Repo.Migrations.AddColourToCalendarIntegrations do
  use Ecto.Migration

  # Nullable and without a default: a null colour means "no override", so the
  # grid keeps colouring this integration by rotation. Existing rows therefore
  # need no backfill.
  def change do
    alter table(:calendar_integrations) do
      add(:colour, :string)
    end
  end
end
