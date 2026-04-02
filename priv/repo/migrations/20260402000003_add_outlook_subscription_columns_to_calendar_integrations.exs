defmodule Tymeslot.Repo.Migrations.AddOutlookSubscriptionColumnsToCalendarIntegrations do
  use Ecto.Migration

  def change do
    alter table(:calendar_integrations) do
      add :graph_subscription_id, :string
      add :graph_subscription_expires_at, :utc_datetime
      add :graph_client_state, :string
      add :graph_delta_link, :text
      add :last_outlook_notification_at, :utc_datetime
    end

    create index(:calendar_integrations, [:graph_subscription_id])
  end
end
