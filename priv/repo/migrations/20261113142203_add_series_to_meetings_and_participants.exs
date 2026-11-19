defmodule Tymeslot.Repo.Migrations.AddSeriesToMeetingsAndParticipants do
  @moduledoc """
  Adds `series_id` and `series_position` to `meetings` and
  `meeting_participants`, so each occurrence of a booking series is an
  ordinary row that knows which series it belongs to and where it sits.

  Both columns are nullable and nothing is backfilled: every existing row is
  a standalone booking. There is deliberately no check pairing the two. A
  nilified `series_id` (the series row gone with its host) leaves the
  position behind, which is harmless; read `series_position` only together
  with `series_id`.

  The partial indexes hold only series rows, serve the foreign key's nilify
  and the occurrence listing, and are built concurrently because both tables
  are large. That needs the migration outside a transaction, and an invalid
  index left by an interrupted build is dropped before building again.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file column_removed
  #
  # The down path drops only the columns this migration added.
  # The new reference columns are nullable and start empty, so adding the
  # foreign key validates no existing row; its index is built concurrently
  # below.

  @disable_ddl_transaction true
  @disable_migration_lock true

  @tables [
    {:meetings, :meetings_series_id_index},
    {:meeting_participants, :meeting_participants_series_id_index}
  ]

  def up do
    for {table, _name} <- @tables do
      alter table(table) do
        add_if_not_exists(
          :series_id,
          references(:booking_series, type: :binary_id, on_delete: :nilify_all)
        )

        add_if_not_exists(:series_position, :integer)
      end
    end

    for {table, name} <- @tables do
      drop_if_exists(index(table, [:series_id], name: name, concurrently: true))

      create(
        index(table, [:series_id],
          name: name,
          where: "series_id IS NOT NULL",
          concurrently: true
        )
      )
    end
  end

  def down do
    for {table, name} <- @tables do
      drop_if_exists(index(table, [:series_id], name: name, concurrently: true))

      alter table(table) do
        remove_if_exists(:series_position, :integer)
        remove_if_exists(:series_id, references(:booking_series, type: :binary_id))
      end
    end
  end
end
