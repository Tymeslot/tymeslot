defmodule Tymeslot.Repo.Migrations.CreateCalendarIntegrations do
  use Ecto.Migration

  def change do
    create table(:calendar_integrations) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :provider, :string, null: false, default: "radicale"
      add :base_url, :string, null: false
      add :username_encrypted, :binary
      add :password_encrypted, :binary
      add :calendar_paths, {:array, :string}, default: []
      add :verify_ssl, :boolean, default: true
      add :is_active, :boolean, default: true
      add :last_sync_at, :utc_datetime
      add :sync_error, :text

      timestamps()
    end

    create index(:calendar_integrations, [:user_id])
    create index(:calendar_integrations, [:is_active])
  end
end
