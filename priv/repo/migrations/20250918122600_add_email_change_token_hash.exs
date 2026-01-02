defmodule Tymeslot.Repo.Migrations.AddEmailChangeTokenHash do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email_change_token_hash, :string
    end

    create unique_index(:users, [:email_change_token_hash])
  end
end
