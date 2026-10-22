defmodule Tymeslot.Repo.Migrations.IndexMeetingsEndTimeNotErased do
  @moduledoc """
  Indexes the end time of meetings whose invitee data has not been erased,
  which is what the retention purge pages through
  (`InviteeDataQueries.meeting_ids_ended_before/2`). On the plain `end_time`
  index every batch walked past every already-anonymised meeting before it
  found a live one, so each daily run rescanned the whole erased history.

  Built concurrently, so it cannot run in a transaction. An interrupted
  build leaves an invalid index of this name behind, which the next run
  drops before building again.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @name :meetings_end_time_not_erased_index

  def up do
    drop_if_exists(index(:meetings, [:end_time], name: @name, concurrently: true))

    create(
      index(:meetings, [:end_time],
        name: @name,
        where: "invitee_data_erased_at IS NULL",
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(index(:meetings, [:end_time], name: @name, concurrently: true))
  end
end
