defmodule Tymeslot.Repo.Migrations.AddOneOffToMeetingTypes do
  use Ecto.Migration

  @moduledoc """
  Marks the meeting types created as one-off events from Quick Add
  (`Tymeslot.MeetingTypes.OneOffEvents`): a fixed-date group type with a
  single planned session, which the dashboard lists apart from the host's
  regular meeting types. Every existing row gets `false`.
  """

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # Migrations run offline: start.sh executes them in a one-shot VM before
  # Phoenix starts, so no request contends for the lock. The default is a
  # constant, which Postgres 11+ records in the catalogue without rewriting
  # the table.

  def change do
    alter table(:meeting_types) do
      add(:one_off, :boolean, null: false, default: false)
    end
  end
end
