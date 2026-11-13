defmodule Tymeslot.Repo.Migrations.AddInvitationOnlyToMeetingTypes do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # A constant default is a metadata-only change on Postgres 11+, no rewrite.
  def change do
    alter table(:meeting_types) do
      add(:invitation_only, :boolean, null: false, default: false)
    end
  end
end
