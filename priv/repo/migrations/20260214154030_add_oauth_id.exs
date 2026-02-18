defmodule Tymeslot.Repo.Migrations.AddGenericOauthIds do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :oauth_user_id, :string
    end

    # Create unique indexes for Generic OAuth IDs
    create_if_not_exists unique_index(:users, [:oauth_user_id])
  end
end
