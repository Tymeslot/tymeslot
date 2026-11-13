defmodule Tymeslot.Repo.Migrations.CreateMeetingTypeInvitations do
  @moduledoc """
  Single-use invitation links for invitation-only meeting types.

  Status is never stored: it is derived from the meetings that carry the
  invitation. The token is held encrypted (`token_encrypted`, so the host can
  be shown the link again) and looked up by its SHA-256 (`token_hash`), as
  poll participant tokens are.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  #
  # The table is created in this same migration and is empty, so the indexes
  # and foreign keys build instantly and nothing can be blocked.
  def change do
    create table(:meeting_type_invitations) do
      add(:meeting_type_id, references(:meeting_types, on_delete: :delete_all), null: false)
      # The host: for ownership scoping and erasure by host.
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:token_encrypted, :binary, null: false)
      add(:token_hash, :string, null: false)
      add(:name, :string)
      # Stored lower-cased.
      add(:email, :string)
      add(:expires_at, :utc_datetime)
      add(:release_on_cancel, :boolean, null: false, default: true)
      add(:revoked_at, :utc_datetime)
      add(:reopened_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:meeting_type_invitations, [:token_hash]))
    create(index(:meeting_type_invitations, [:meeting_type_id, :inserted_at]))
    create(index(:meeting_type_invitations, [:user_id]))
  end
end
