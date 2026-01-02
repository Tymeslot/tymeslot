defmodule Tymeslot.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :email, :string, null: false
      add :password_hash, :string
      add :verified_at, :utc_datetime
      add :verification_token, :string
      add :verification_sent_at, :utc_datetime
      add :reset_token, :string
      add :reset_sent_at, :utc_datetime
      add :name, :string
      add :provider, :string
      add :provider_uid, :string
      add :provider_email, :string
      add :provider_meta, :map

      timestamps()
    end

    create unique_index(:users, [:email])
    create unique_index(:users, [:verification_token])
    create unique_index(:users, [:reset_token])
    create unique_index(:users, [:provider, :provider_uid])
  end
end
