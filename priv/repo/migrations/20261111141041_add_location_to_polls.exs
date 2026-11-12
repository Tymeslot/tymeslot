defmodule Tymeslot.Repo.Migrations.AddLocationToPolls do
  @moduledoc """
  Gives a poll a location of its own, as the host chose it: a video call on
  one of their video integrations, one of their saved venues, or a place
  they typed in. Every existing poll starts with none, and so keeps reading
  its location from its meeting type, as before.

  The venue and the integration are nilified when they are deleted: the
  poll then has no location of its own rather than failing to load. The
  kind is closed at the database layer as the schema's `Ecto.Enum` closes
  it; every row is NULL when the constraint is added, so it validates no
  existing data.
  """

  use Ecto.Migration

  # `polls` is small (one row per poll a host has made), and migrations run
  # offline before Phoenix starts (`start.sh`), so building the two indexes
  # and the constraint inside the migration's transaction blocks no live
  # traffic. The references are new, nullable columns.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file check_constraint_added

  def change do
    alter table(:polls) do
      add(:location_kind, :string)
      add(:location_details, :text)
      add(:venue_id, references(:venues, on_delete: :nilify_all))
      add(:video_integration_id, references(:video_integrations, on_delete: :nilify_all))
    end

    create(index(:polls, [:venue_id]))
    create(index(:polls, [:video_integration_id]))

    create(
      constraint(:polls, :polls_location_kind_must_be_known,
        check: "location_kind IS NULL OR location_kind IN ('video', 'in_person', 'custom')"
      )
    )
  end
end
