defmodule Tymeslot.Repo.Migrations.AddBatchToAdminAlertDigestEntries do
  use Ecto.Migration

  # Which email a waiting entry goes out in: "daily", the digest of info
  # alerts, or "errors", the roll-up of error alerts over the per-hour cap.
  # Every existing row is a daily digest entry, which the default records.
  def change do
    alter table(:admin_alert_digest_entries) do
      # A constant default is a catalogue-only change on PostgreSQL 11 and
      # later: no table rewrite, and the table holds at most a day of rows.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add(:batch, :string, null: false, default: "daily")
    end
  end
end
