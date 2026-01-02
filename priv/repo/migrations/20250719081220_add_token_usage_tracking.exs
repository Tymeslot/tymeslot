defmodule Tymeslot.Repo.Migrations.AddTokenUsageTracking do
  use Ecto.Migration

  def change do
    # Add used_at fields to track when tokens are consumed
    alter table(:users) do
      add :verification_token_used_at, :utc_datetime
      add :reset_token_used_at, :utc_datetime
    end

    # Create indexes for faster token lookups
    create_if_not_exists index(:users, [:verification_token])
    create_if_not_exists index(:users, [:reset_token])
  end
end