defmodule Tymeslot.Repo.Migrations.CreateOauthPendingFlows do
  use Ecto.Migration

  # The table is created here, empty, so its reference and indexes lock and
  # validate nothing that already exists.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  # One row per integration OAuth flow a user has started: the PKCE code
  # verifier the callback must present, and whether the callback has already
  # spent it.
  def change do
    create table(:oauth_pending_flows) do
      add :nonce, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :code_verifier_encrypted, :binary, null: false
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:oauth_pending_flows, [:nonce])
    create index(:oauth_pending_flows, [:user_id])
    create index(:oauth_pending_flows, [:expires_at])
  end
end
