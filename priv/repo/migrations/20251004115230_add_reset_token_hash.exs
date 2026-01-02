defmodule Tymeslot.Repo.Migrations.AddResetTokenHash do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :reset_token_hash, :string
    end

    create unique_index(:users, [:reset_token_hash])
  end
end