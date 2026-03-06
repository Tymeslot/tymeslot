defmodule Tymeslot.Repo.Migrations.AddLinkTokenToTelegramIntegrations do
  use Ecto.Migration

  def change do
    alter table(:telegram_integrations) do
      add :link_token, :string
    end

    create unique_index(:telegram_integrations, [:link_token],
             where: "link_token IS NOT NULL"
           )
  end
end
