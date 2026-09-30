defmodule Tymeslot.Repo.Migrations.CreateVenues do
  @moduledoc """
  Saved venues: the places an organiser meets people, kept once per account
  and referenced by id from the in-person locations of their meeting types.

  `position` is the organiser's own order for their venues, set by drag and
  drop on the Locations page and used wherever venues are listed.

  `meetings.venue_id` pins which venue a booking was made at, so a reschedule
  can open on it. It is nullable and nilified when the venue goes: the
  meeting's `location` text is the record of where it was booked.
  """
  use Ecto.Migration

  # The table is created empty in this migration, so its unique index and its
  # reference to users cannot lock or rewrite anything. `meetings.venue_id` is
  # a new nullable column with no default; Tymeslot deploys as a single
  # instance and migrates with the app stopped, so the brief lock while its
  # foreign key and index are added is acceptable. The column and table
  # removals are confined to `down/0`.
  # `position`'s default is part of CREATE TABLE, so it rewrites no rows.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file table_dropped

  def up do
    create table(:venues) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:name, :string, size: 120, null: false)
      add(:description, :text)
      add(:position, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:venues, [:user_id, :name]))

    alter table(:meetings) do
      add(:venue_id, references(:venues, on_delete: :nilify_all))
    end

    create(index(:meetings, [:venue_id]))
  end

  def down do
    alter table(:meetings) do
      remove(:venue_id)
    end

    drop(table(:venues))
  end
end
