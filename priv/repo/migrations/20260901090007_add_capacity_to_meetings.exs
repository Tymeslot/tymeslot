defmodule Tymeslot.Repo.Migrations.AddCapacityToMeetings do
  @moduledoc """
  Snapshots seat capacity onto the meeting row itself.

  Group-ness and capacity were previously re-derived per consumer (live
  participant counts, `meeting_type_ref.max_participants`), and the
  predicates disagreed at the edges. `capacity` is written once, at slot
  creation, exactly like `title`/`organizer_name` already are: a solo
  meeting is always `1`, a group meeting keeps the seat count it was booked
  with even if the type's `max_participants` later changes or the type is
  deleted.
  """

  use Ecto.Migration

  # The backfill below is a bounded one-off UPDATE over existing rows: every
  # meeting booked before this column existed must recover its capacity from
  # the meeting type it was booked against, and there is no online variant of
  # "populate a column from a join".
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update

  def up do
    alter table(:meetings) do
      # `1` is a constant, not a volatile expression, so from PostgreSQL 11
      # onwards this is a catalogue-only change: the default is recorded once
      # and existing rows read it without a table rewrite (same reasoning as
      # add_max_participants_to_meeting_types.exs).
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :capacity, :integer, default: 1, null: false
    end

    # Recover the capacity of existing group bookings from the meeting type
    # they were booked against. Meetings whose type has since been deleted
    # (`meeting_type_id` nilified by `on_delete: :nilify_all`) cannot be
    # recovered this way and keep the column default of `1` — the same
    # fallback a group booking gets if its capacity is ever unknown.
    execute("""
    UPDATE meetings
    SET capacity = meeting_types.max_participants
    FROM meeting_types
    WHERE meetings.meeting_type_id = meeting_types.id
      AND meeting_types.max_participants > 1
    """)
  end

  def down do
    alter table(:meetings) do
      # Dropping the column is the whole point of the rollback, and it only
      # ever runs deliberately.
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove :capacity
    end
  end
end
