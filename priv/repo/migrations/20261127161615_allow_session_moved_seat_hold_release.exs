defmodule Tymeslot.Repo.Migrations.AllowSessionMovedSeatHoldRelease do
  @moduledoc """
  Admits `session_moved` as a seat hold's release reason: a hold still open
  when its host moves the planned session is released, as its booker never
  chose the new time.

  `up/0` only widens the set of allowed reasons, so every existing row
  satisfies the new check. `down/0` narrows it again, first settling any
  `session_moved` release as `meeting_cancelled`, the reason whose payment
  handling (a refund, never a conversion) it shares.
  """

  use Ecto.Migration

  # Migrations run offline (`start.sh` runs them before Phoenix starts), and
  # the widened check admits every row the old one did, so validating it
  # holds the table's lock only for one scan of a small table.
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  #
  # The rollback's backfill is one set-based statement.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  @old_reasons "'expired', 'failed', 'abandoned', 'meeting_cancelled'"
  @new_reasons @old_reasons <> ", 'session_moved'"

  def up do
    replace_reason_check(@new_reasons)
  end

  def down do
    execute("""
    UPDATE seat_holds
    SET released_reason = 'meeting_cancelled'
    WHERE released_reason = 'session_moved'
    """)

    replace_reason_check(@old_reasons)
  end

  defp replace_reason_check(reasons) do
    drop_if_exists constraint(:seat_holds, :seat_holds_released_reason_must_be_known)

    create constraint(:seat_holds, :seat_holds_released_reason_must_be_known,
             check: "released_reason IS NULL OR released_reason IN (#{reasons})"
           )
  end
end
