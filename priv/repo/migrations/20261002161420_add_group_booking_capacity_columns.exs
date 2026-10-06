defmodule Tymeslot.Repo.Migrations.AddGroupBookingCapacityColumns do
  @moduledoc """
  Adds seat counts for group bookings.

    * `meeting_types.max_participants`: how many people may book one slot of
      the type. `1` is an ordinary one-to-one type.
    * `meetings.capacity`: the seat count snapshotted onto the slot itself
      when it is created, exactly like `title` and `organizer_name` already
      are. A value above `1` is what marks a group meeting. Every existing
      meeting is a one-to-one booking, so the default of `1` is correct for
      all of them and nothing is backfilled.
  """

  use Ecto.Migration

  def change do
    # Both defaults are the constant `1`, not a volatile expression, so from
    # PostgreSQL 11 onwards each add is a catalogue-only change: the default is
    # recorded once and existing rows read it without a table rewrite. The
    # project requires PostgreSQL 14 or newer (README), so every supported
    # version takes the cheap path.
    alter table(:meeting_types) do
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :max_participants, :integer, default: 1, null: false
    end

    alter table(:meetings) do
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :capacity, :integer, default: 1, null: false
    end
  end
end
