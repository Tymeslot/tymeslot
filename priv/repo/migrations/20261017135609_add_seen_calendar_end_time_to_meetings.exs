defmodule Tymeslot.Repo.Migrations.AddSeenCalendarEndTimeToMeetings do
  @moduledoc """
  Records the end the host's calendar event showed for a meeting at the last
  sync that found it in step, so that a meeting follows an end the host
  changes there rather than every end that differs from its own.

  NULL, the state of every existing row, means no end has been seen yet: the
  next sync takes whatever end the calendar shows as the starting point and
  changes nothing. An end that already differed before this column existed
  (one the host changed while the meeting did not yet follow such changes) is
  left as it is, and no attendee is told of a change that was never made now.
  There is nothing to backfill.
  """
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add(:seen_calendar_end_time, :utc_datetime)
    end
  end
end
