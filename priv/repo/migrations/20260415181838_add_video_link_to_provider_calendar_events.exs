defmodule Tymeslot.Repo.Migrations.AddVideoLinkToProviderCalendarEvents do
  use Ecto.Migration

  def up do
    alter table(:provider_calendar_events) do
      add :video_link, :string, null: true
    end
  end

  def down do
    alter table(:provider_calendar_events) do
      remove :video_link
    end
  end
end
