defmodule Tymeslot.Repo.Migrations.CreateMeetingTypeOfferedTimes do
  use Ecto.Migration

  # The reference and the index are created against a table this same
  # migration creates: it holds no rows yet, so there is no lock contention or
  # table rewrite to avoid by adding them concurrently or in a later migration.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  # The exact start times a one-to-one meeting type with fixed dates offers
  # (`Tymeslot.MeetingTypes.OfferedTimes`). Unlike a group type's planned
  # sessions they are not meetings: a booking of one is an ordinary meeting,
  # and the time stops being offered because that meeting conflicts with it.
  # The rows go with their meeting type.
  def change do
    create table(:meeting_type_offered_times) do
      add(:meeting_type_id, references(:meeting_types, on_delete: :delete_all), null: false)
      add(:starts_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    # One row per start: the unique index also serves the per-type reads,
    # which filter on the type and order by the start.
    create(unique_index(:meeting_type_offered_times, [:meeting_type_id, :starts_at]))

    # The daily retention run deletes every type's past times by start.
    create(index(:meeting_type_offered_times, [:starts_at]))
  end
end
