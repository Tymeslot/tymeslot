defmodule Tymeslot.Repo.Migrations.AddUsernameToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :username, :string
    end

    create unique_index(:profiles, [:username])
  end
end
