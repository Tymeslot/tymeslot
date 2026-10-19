defmodule Tymeslot.Repo.Migrations.AddNotifiedEndTimeToMeetingSeats do
  @moduledoc """
  Records, per seat (the booker on `meetings`, each group participant, each
  guest), the end that seat was last told by an end change notice, or held
  before a change not yet announced. NULL, the state of every existing row,
  means the seat knows the meeting as it was booked or last rescheduled, so
  there is nothing to backfill.
  """
  use Ecto.Migration

  def change do
    for table <- [:meetings, :meeting_participants, :meeting_guests] do
      alter table(table) do
        add :notified_end_time, :utc_datetime
      end
    end
  end
end
