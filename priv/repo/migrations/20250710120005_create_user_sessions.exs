defmodule Tymeslot.Repo.Migrations.CreateUserSessions do
  use Ecto.Migration

  def change do
    create table(:user_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps()
    end

    create index(:user_sessions, [:user_id])
    create unique_index(:user_sessions, [:token])
  end
end
