defmodule Tymeslot.Repo.Migrations.MakePendingEmailUnique do
  use Ecto.Migration

  def change do
    drop_if_exists(index(:users, [:pending_email]))
    create(unique_index(:users, [:pending_email]))
  end
end
