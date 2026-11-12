defmodule Tymeslot.Repo.Migrations.AddRequiresEmailVerificationToMeetingTypes do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # A constant default is a catalogue-only change on Postgres 11+, and existing
  # rows read false, the safe default.
  def change do
    alter table(:meeting_types) do
      add(:requires_email_verification, :boolean, null: false, default: false)
    end
  end
end
