defmodule Tymeslot.Repo.Migrations.AddFullNameToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :full_name, :string
    end
  end
end
