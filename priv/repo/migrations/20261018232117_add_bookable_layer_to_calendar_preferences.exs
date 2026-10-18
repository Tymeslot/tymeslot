defmodule Tymeslot.Repo.Migrations.AddBookableLayerToCalendarPreferences do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # The default is a constant, which PostgreSQL 11 and later store in the
  # catalogue rather than rewriting the table for. Tymeslot deploys as a
  # single instance and migrates with the app stopped, so the brief locks
  # while the column, the foreign key and its index are added block no
  # traffic. calendar_preferences holds one row per organiser.

  # The new calendar's bookable-times layer: whether it shows (on for
  # everyone, existing rows included, so no backfill is needed and NOT NULL
  # holds at once) and which meeting type it shows. The meeting type is
  # optional: nil means "the first active one", and deleting the chosen type
  # clears the choice rather than the preferences.
  def change do
    alter table(:calendar_preferences) do
      add(:bookable_layer, :boolean, null: false, default: true)
      add(:bookable_meeting_type_id, references(:meeting_types, on_delete: :nilify_all))
    end

    create(index(:calendar_preferences, [:bookable_meeting_type_id]))
  end
end
