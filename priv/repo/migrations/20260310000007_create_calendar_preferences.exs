defmodule Tymeslot.Repo.Migrations.CreateCalendarPreferences do
  use Ecto.Migration

  def change do
    create table(:calendar_preferences) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :default_view, :string, default: "week", null: false
      add :hidden_integration_ids, {:array, :bigint}, default: [], null: false

      timestamps()
    end

    create unique_index(:calendar_preferences, [:user_id])
  end
end
