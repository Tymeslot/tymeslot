defmodule Tymeslot.Repo.Migrations.AllowExtraHoursOverrides do
  use Ecto.Migration

  @moduledoc """
  Lets a schedule hold extra available times on a date, besides its weekly
  hours: `availability_overrides` rows of type `extra_hours`, several per
  date allowed. The other override types stay one per schedule and date, so
  the unique index becomes partial, and the type check admits the new type.
  """

  def up do
    execute("ALTER TABLE availability_overrides DROP CONSTRAINT override_type_check")

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

    execute("ALTER TABLE availability_overrides DROP CONSTRAINT override_type_check")

    execute(
      "ALTER TABLE availability_overrides ADD CONSTRAINT override_type_check " <>
        "CHECK (override_type IN ('unavailable', 'custom_hours', 'available'))"
    )
  end
end
