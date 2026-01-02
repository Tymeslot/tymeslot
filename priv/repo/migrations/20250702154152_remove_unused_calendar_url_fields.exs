defmodule Tymeslot.Repo.Migrations.RemoveUnusedCalendarUrlFields do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      # Remove unused calendar URL fields - we only attach .ics files
      remove :google_calendar_url
      remove :outlook_calendar_url
      remove :ics_download_url
    end
  end
end
