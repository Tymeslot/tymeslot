defmodule Tymeslot.Repo.Migrations.DropPlaintextResetToken do
  use Ecto.Migration

  def change do
    drop_if_exists index(:users, [:reset_token])

    alter table(:users) do
      remove :reset_token
    end
  end
end