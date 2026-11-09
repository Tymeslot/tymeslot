defmodule Tymeslot.Repo.Migrations.CreateUserSmtpSettings do
  @moduledoc """
  Adds opt-in user SMTP identities without changing existing mail delivery.
  Credentials and test evidence share the same revisioned ownership boundary.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # All definitions apply to the new, empty table in this transaction. No
  # existing settings are scanned or rewritten, and its index builds before
  # any application can insert a row. No users-table backfill is required.

  @doc "Creates the owned settings table and its lifecycle invariants."
  def change do
    create table(:user_smtp_settings) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:host, :string, size: 253, null: false)
      add(:port, :integer, null: false)
      add(:security, :string, null: false)
      add(:username_encrypted, :binary, null: false)
      add(:password_encrypted, :binary, null: false)
      add(:from_address, :string, size: 254, null: false)
      add(:from_name, :string, null: false)
      add(:enabled, :boolean, null: false, default: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:tested_revision, :bigint)
      add(:tested_at, :utc_datetime_usec)
      add(:last_error, :string)
      add(:last_failed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:user_smtp_settings, [:user_id]))

    create(
      constraint(:user_smtp_settings, :user_smtp_settings_transport,
        check:
          "(port = 465 AND security = 'implicit_tls') OR (port = 587 AND security = 'starttls')"
      )
    )

    create(
      constraint(:user_smtp_settings, :user_smtp_settings_revision,
        check:
          "revision > 0 AND (tested_revision IS NULL OR (tested_revision > 0 AND tested_revision <= revision))"
      )
    )

    # SQL CHECK treats NULL as satisfied; test evidence needs explicit IS NOT
    # NULL checks so an enabled row can never bypass activation validation.
    create(
      constraint(:user_smtp_settings, :user_smtp_settings_activation,
        check:
          "NOT enabled OR (tested_revision IS NOT NULL AND tested_revision = revision AND tested_at IS NOT NULL)"
      )
    )
  end
end
