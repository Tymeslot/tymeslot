defmodule Tymeslot.Repo.Migrations.AddTrackingToMeetings do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :utm_source, :string
      add :utm_medium, :string
      add :utm_campaign, :string
      add :utm_content, :string
      add :utm_term, :string
      add :referrer_host, :string
      add :tracking_params, :map, default: %{}, null: false
    end

    create index(:meetings, [:utm_source])
    create index(:meetings, [:utm_campaign])
  end
end
