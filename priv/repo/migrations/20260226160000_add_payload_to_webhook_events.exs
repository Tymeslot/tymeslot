defmodule Tymeslot.Repo.Migrations.AddPayloadToWebhookEvents do
  use Ecto.Migration

  def change do
    alter table(:webhook_events) do
      add :payload, :jsonb
    end
  end
end
