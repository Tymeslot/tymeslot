defmodule Tymeslot.Repo.Migrations.AddAttendeeTimezoneToMeetings do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :attendee_timezone, :string
    end
  end
end
