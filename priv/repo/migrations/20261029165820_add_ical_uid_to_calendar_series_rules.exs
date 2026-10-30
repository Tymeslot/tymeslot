defmodule Tymeslot.Repo.Migrations.AddIcalUidToCalendarSeriesRules do
  use Ecto.Migration

  # The iCalendar UID of the series' master, read with its rule. Outlook gives
  # every occurrence a UID of its own, so an email about one occurrence can
  # name the series its guests were invited to only from the master's.
  # Nullable: existing rows gain it on their next read.
  def change do
    alter table(:calendar_series_rules) do
      add :ical_uid, :string
    end
  end
end
