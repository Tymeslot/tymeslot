defmodule Tymeslot.Repo.Migrations.AddRawIcalToProviderCalendarEvents do
  use Ecto.Migration

  def change do
    alter table(:provider_calendar_events) do
      # Raw VCALENDAR/VEVENT body as received from the server. Optional —
      # existing rows are populated on the next sync. Storing the raw body
      # lets a parser improvement re-parse cached events in place without
      # re-fetching them from the server.
      add(:raw_ical, :text)
    end
  end
end
