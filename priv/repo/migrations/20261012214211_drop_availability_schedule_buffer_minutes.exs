defmodule Tymeslot.Repo.Migrations.DropAvailabilityScheduleBufferMinutes do
  use Ecto.Migration

  @moduledoc """
  Drops `availability_schedules.buffer_minutes`, the single buffer that
  `20261002130255_split_availability_schedule_buffers` replaced with
  `buffer_before_minutes` and `buffer_after_minutes`.

  This is the contract half of that expand/contract change. The split kept
  the column, unread, so that the release before it could still be rolled
  back to; nothing has read or written it since, so it holds each schedule's
  buffer as it stood at that upgrade (or the default 15 for schedules created
  since). From this release on, going back to a version before the split
  needs a database restore.

  The before/after pair is not refreshed from `buffer_minutes` first. A
  schedule written through a rolled-back image would have a newer
  `buffer_minutes` than its pair, but nothing can tell such a row from one
  whose `buffer_minutes` is merely stale, and copying it across would
  overwrite every buffer edit made since the upgrade.

  Rolling back restores the column with the larger of the two buffers, as
  the split's own `down/0` does, so a rolled-back schedule never offers a
  slot its asymmetric pair would have refused.
  """

  # excellent_migrations:safety-assured-for-this-file column_removed
  # The column has been unread since the split release, and that release is
  # no longer a supported rollback target. Migrations run offline (start.sh
  # runs them in a one-shot VM before Phoenix starts), so no request holds
  # the table while the column goes.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Only `down/0` adds the column back, with a constant default that Postgres
  # 11+ records without rewriting the table, and refills it with one UPDATE.

  def up do
    alter table(:availability_schedules) do
      remove_if_exists(:buffer_minutes, :integer)
    end
  end

  def down do
    alter table(:availability_schedules) do
      add_if_not_exists(:buffer_minutes, :integer, null: false, default: 15)
    end

    execute("""
    UPDATE availability_schedules
    SET buffer_minutes = GREATEST(buffer_before_minutes, buffer_after_minutes)
    """)
  end
end
