defmodule Tymeslot.Repo.Migrations.AddEmailChangeFields do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :pending_email, :string
      add :email_change_token, :string
      add :email_change_sent_at, :utc_datetime
      add :email_change_confirmed_at, :utc_datetime
    end

    create unique_index(:users, [:email_change_token])
    create index(:users, [:pending_email])
  end
end