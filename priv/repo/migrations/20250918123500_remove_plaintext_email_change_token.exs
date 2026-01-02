defmodule Tymeslot.Repo.Migrations.RemovePlaintextEmailChangeToken do
  use Ecto.Migration

  def up do
    # Drop unique index on email_change_token if it exists
    drop_if_exists index(:users, [:email_change_token])

    # Remove plaintext token column
    alter table(:users) do
      remove :email_change_token
    end
  end

  def down do
    alter table(:users) do
      add :email_change_token, :string
    end

    create unique_index(:users, [:email_change_token])
  end
end
