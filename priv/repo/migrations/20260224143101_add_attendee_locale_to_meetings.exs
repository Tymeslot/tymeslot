defmodule Tymeslot.Repo.Migrations.AddAttendeeLocaleToMeetings do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :attendee_locale, :string, size: 10, default: "en", null: false
    end
  end
end
