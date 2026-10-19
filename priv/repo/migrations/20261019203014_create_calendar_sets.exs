defmodule Tymeslot.Repo.Migrations.CreateCalendarSets do
  @moduledoc """
  Calendar sets: named groups of calendars the organiser switches between
  with the keys 1 to 9 on the new calendar. A set lists the calendars it
  shows (`members`: an integration id and a calendar id, or no calendar id
  for a whole account), and the preferences name the active one. Applying a
  set writes only that id, so the organiser's own hidden choices stay as
  they were.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # calendar_sets is created here, empty, so its reference, unique index and
  # check validate nothing that already exists. calendar_preferences gains a
  # nullable reference with no default (every organiser starts with no set,
  # so nothing needs a backfill) and its index; the table holds one row per
  # organiser, and Tymeslot migrates with the app stopped, so the brief
  # locks block no traffic.

  def up do
    create table(:calendar_sets) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :position, :integer, null: false
      add :members, {:array, :map}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    # One set per digit; also the index behind the user's cascade delete.
    create unique_index(:calendar_sets, [:user_id, :position])

    create constraint(:calendar_sets, :calendar_sets_position_range,
             check: "position BETWEEN 1 AND 9"
           )

    # Deleting the active set leaves no set active.
    alter table(:calendar_preferences) do
      add :active_calendar_set_id, references(:calendar_sets, on_delete: :nilify_all)
    end

    create index(:calendar_preferences, [:active_calendar_set_id])
  end

  def down do
    drop index(:calendar_preferences, [:active_calendar_set_id])

    # Undoes only this migration's own column and table.
    alter table(:calendar_preferences) do
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove :active_calendar_set_id
    end

    # excellent_migrations:safety-assured-for-next-line table_dropped
    drop table(:calendar_sets)
  end
end
