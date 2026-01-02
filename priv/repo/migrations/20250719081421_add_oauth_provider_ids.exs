defmodule Tymeslot.Repo.Migrations.AddOauthProviderIds do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :github_user_id, :string
      add :google_user_id, :string
    end

    # Create unique indexes for OAuth provider IDs
    create_if_not_exists unique_index(:users, [:github_user_id])
    create_if_not_exists unique_index(:users, [:google_user_id])
  end
end