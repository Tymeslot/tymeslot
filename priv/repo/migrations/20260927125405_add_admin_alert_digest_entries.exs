defmodule Tymeslot.Repo.Migrations.AddAdminAlertDigestEntries do
  use Ecto.Migration

  # Info-severity admin alerts wait here for the daily digest email instead of
  # each sending its own. One row per distinct alert (its dedup hash), so a
  # repeat within a day raises the row's count rather than adding a row.
  def change do
    create table(:admin_alert_digest_entries) do
      add(:alert_type, :string, null: false)
      add(:category, :string, null: false)
      add(:message, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:alert_hash, :string, null: false)
      add(:occurrences, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    # The table is created empty a line above, so there is nothing to lock.
    # excellent_migrations:safety-assured-for-next-line index_not_concurrently
    create(unique_index(:admin_alert_digest_entries, [:alert_hash]))
  end
end
