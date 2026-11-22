defmodule Tymeslot.Repo.Migrations.DateExpiredMeetingsToTheirDeadline do
  @moduledoc """
  Dates every meeting that expired at a deadline to that deadline.

  Until this release, each expiry stamped `cancelled_at` (and, for an
  approval, `approval_resolved_at`) with the moment the expiry ran, however
  long after the deadline that was. The 1.48.0 deploy made it months for
  reschedule requests already open when they first became able to lapse, and
  the outstanding refunds screen shows and orders expired meetings by that
  date. Three kinds of expired row are rewritten:

    * **A lapsed reschedule request**: `expired` with `reschedule_requested_at`
      set, since a request cannot be made while a meeting awaits approval and
      answering one clears the stamp. Its deadline is the later of its start
      and the answer window after the request, the rule
      `Tymeslot.Meetings.MeetingState.reschedule_request_deadline/1` applies,
      restated so the migration keeps its meaning if that code changes. The
      window is read from the same config key, as the release loads its
      configuration before migrating.
    * **A booking request nobody approved**: `expired` with
      `approval_resolved_at`, `approval_deadline_at` and `cancelled_at` set,
      no decline and no reschedule request. An approval keeps the deadline
      and stamps `approval_resolved_at` too, so those two alone would also
      match a meeting approved and expired later some other way; the other
      guards rule each of those out. A lapsed reschedule request leaves
      `reschedule_requested_at` set (the first kind), and a checkout never
      completed expires the meeting without stamping `cancelled_at`.
    * **A booking nobody verified**: `expired` with a
      `verification_deadline_at`, never verified and never through the
      approval gate.

  Each is dated to its deadline, never later than when it was stamped, so an
  expiry that ran on time moves by the seconds its job took. Running it twice
  changes nothing. Rolling back leaves the dates, which are the correct ones.
  """
  use Ecto.Migration

  def up do
    days = Application.get_env(:tymeslot, :reschedule_answer_days, 7)
    true = is_integer(days) and days > 0

    # One-shot data repairs with no migration DSL form. They touch only
    # expired meetings, a small set, under row locks.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meetings
    SET cancelled_at = LEAST(cancelled_at, date_trunc('second',
          GREATEST(start_time, reschedule_requested_at + make_interval(days => #{days}))))
    WHERE status = 'expired'
      AND reschedule_requested_at IS NOT NULL
      AND start_time IS NOT NULL
      AND cancelled_at IS NOT NULL
    """)

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meetings
    SET cancelled_at = LEAST(cancelled_at, date_trunc('second', approval_deadline_at)),
        approval_resolved_at = LEAST(approval_resolved_at, date_trunc('second', approval_deadline_at))
    WHERE status = 'expired'
      AND reschedule_requested_at IS NULL
      AND approval_deadline_at IS NOT NULL
      AND approval_resolved_at IS NOT NULL
      AND approval_declined_at IS NULL
      AND cancelled_at IS NOT NULL
    """)

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE meetings
    SET cancelled_at = LEAST(cancelled_at, date_trunc('second', verification_deadline_at))
    WHERE status = 'expired'
      AND reschedule_requested_at IS NULL
      AND approval_resolved_at IS NULL
      AND verification_deadline_at IS NOT NULL
      AND email_verified_at IS NULL
      AND cancelled_at IS NOT NULL
    """)
  end

  def down, do: :ok
end
