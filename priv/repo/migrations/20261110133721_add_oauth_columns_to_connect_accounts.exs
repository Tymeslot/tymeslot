defmodule Tymeslot.Repo.Migrations.AddOauthColumnsToConnectAccounts do
  use Ecto.Migration

  def change do
    alter table(:connect_accounts) do
      # Non-null: connected through OAuth. Null: legacy AccountLink row or placeholder.
      add :oauth_connected_at, :utc_datetime
      # Single-use marker for an authorise attempt in flight.
      add :oauth_nonce, :string
    end
  end
end
