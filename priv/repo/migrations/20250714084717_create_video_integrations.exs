defmodule Tymeslot.Repo.Migrations.CreateVideoIntegrations do
  use Ecto.Migration

  def change do
    create table(:video_integrations) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :provider, :string, null: false, default: "mirotalk"
      add :base_url, :string, null: false
      add :api_key_encrypted, :binary
      add :is_active, :boolean, default: true
      add :is_default, :boolean, default: false
      add :settings, :map, default: %{}

      timestamps()
    end

    create index(:video_integrations, [:user_id])
    create unique_index(:video_integrations, [:user_id, :is_default], where: "is_default = true", name: :one_default_per_user)
  end
end
