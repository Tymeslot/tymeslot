defmodule Tymeslot.Repo.Migrations.AllowExtraHoursOverrides do
  use Ecto.Migration

  @moduledoc """
  Lets a schedule hold extra available times on a date, besides its weekly
  hours: `availability_overrides` rows of type `extra_hours`, several per
  date allowed. The other override types stay one per schedule and date, so
  the unique index becomes partial, and the type check admits the new type.

  This migration first ran under the version `20261016120000`. Running it
  again on a database that already has it is harmless: it replaces the type
  check and the index with the same ones.
  """

  # Swapping a CHECK constraint means dropping the old one and adding the new
  # one, which Ecto's constraint helpers cannot express as one step; the
  # rollback's DELETE is raw by nature. The index is rebuilt in the same
  # transaction rather than concurrently so the table is never without its
  # uniqueness rule. Reviewed: the table is small (a row per date a schedule
  # departs from its weekly hours), and the new check admits every existing
  # row, since its list is a superset of the old one.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  def up do
    execute("ALTER TABLE availability_overrides DROP CONSTRAINT IF EXISTS override_type_check")

    execute(
      "ALTER TABLE availability_overrides ADD CONSTRAINT override_type_check " <>
        "CHECK (override_type IN ('unavailable', 'custom_hours', 'available', 'extra_hours'))"
    )

    drop_if_exists(unique_index(:availability_overrides, [:schedule_id, :date]))

    create(
      unique_index(:availability_overrides, [:schedule_id, :date],
        where: "override_type <> 'extra_hours'"
      )
    )
  end

  # Extra times cannot survive a unique index over every row.
  def down do
    execute("DELETE FROM availability_overrides WHERE override_type = 'extra_hours'")
    drop_if_exists(unique_index(:availability_overrides, [:schedule_id, :date]))
    create(unique_index(:availability_overrides, [:schedule_id, :date]))

    execute("ALTER TABLE availability_overrides DROP CONSTRAINT IF EXISTS override_type_check")

    execute(
      "ALTER TABLE availability_overrides ADD CONSTRAINT override_type_check " <>
        "CHECK (override_type IN ('unavailable', 'custom_hours', 'available'))"
    )
  end
end
