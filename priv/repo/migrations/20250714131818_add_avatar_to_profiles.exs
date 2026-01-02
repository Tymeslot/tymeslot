defmodule Tymeslot.Repo.Migrations.AddAvatarToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :avatar, :string
    end
  end
end
