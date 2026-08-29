defmodule Tymeslot.Repo.Migrations.AddAnnouncedAtToMeetings do
  use Ecto.Migration

  # Records the moment `meeting.created` was raised for a meeting, so the event
  # can be claimed once and never fan out twice. Nullable and without a default:
  # meetings that predate this column were announced before it existed, and a
  # backfill would have to invent a timestamp for an event already delivered.
  # Leaving them NULL means a re-announcement is still possible for a meeting
  # created before the deploy, which is the pre-existing behaviour rather than a
  # regression, and only reachable while such a meeting is still in flight.
  def change do
    alter table(:meetings) do
      add(:announced_at, :utc_datetime)
    end
  end
end
