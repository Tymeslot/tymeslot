defmodule Tymeslot.Repo.Migrations.BackfillFirstAnnouncedAtForPreAnnouncementBookings do
  use Ecto.Migration

  # `20260903105820_add_first_announced_at_to_meetings` backfilled from
  # `announced_at`, which only reaches back as far as the column itself:
  # `20260829153951_add_announced_at_to_meetings` added it without a backfill,
  # so every booking confirmed before that deploy carries NULL there. Copying
  # NULL forward therefore left the great majority of live bookings with no
  # record that they were ever announced, which is precisely the state
  # `Meetings.Approval.refund_unapproved_request/1` reads as "never a
  # confirmed meeting": one of those bookings, paid for, rescheduled into a
  # meeting type that now requires approval and then declined, is refunded in
  # full automatically instead of leaving the host the refund choice.
  #
  # This is a second migration rather than an edit to the first because the
  # first has already run on every development database; production has not
  # seen either, so it gets the corrected end state from the pair.
  #
  # `inserted_at` is the stand-in timestamp. The exact instant does not
  # matter to any reader — `first_announced_at` is only ever tested for
  # presence — and the row's creation is the closest thing on it to when the
  # booking became a meeting.
  #
  # Only `confirmed` and `completed` are stamped:
  #
  #   * `cancelled` is excluded because a cancelled meeting cannot be
  #     rescheduled, so it can never re-enter the approval gate, and the
  #     status is reachable from `awaiting_approval` as well as from
  #     `confirmed` — stamping it would assert a history the row does not
  #     have.
  #   * `reschedule_requested` (a legacy status no code writes any more) is
  #     excluded for the same reason: `Bookings.Reschedule.reenters_gate?/1`
  #     re-gates only `confirmed` and `awaiting_approval`, so a row carrying
  #     it cannot reach the refund rule.
  #   * `pending`, `awaiting_payment`, `awaiting_approval` and `expired` were
  #     never announced, and must keep reading that way.

  def up do
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meetings
    SET first_announced_at = COALESCE(announced_at, inserted_at)
    WHERE first_announced_at IS NULL
      AND status IN ('confirmed', 'completed')
    """)
  end

  # Irreversible: once stamped, a row backfilled here is indistinguishable
  # from one stamped by the announcement itself, so there is nothing to
  # single out and clear. Rolling back the column at all means rolling back
  # `20260903105820`, which drops it outright.
  def down, do: :ok
end
