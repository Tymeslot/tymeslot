defmodule Tymeslot.Repo.Migrations.CreateConnectAccounts do
  @moduledoc """
  One row per Tymeslot host who has started Stripe Connect onboarding.
  user_id is a nilify FK so the row survives user deletion (retention).
  """

  use Ecto.Migration

  def change do
    create table(:connect_accounts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, on_delete: :nilify_all), null: true)
      add(:stripe_account_id, :string)
      add(:country, :string, size: 2)
      add(:default_currency, :string, size: 3)
      add(:charges_enabled, :boolean, default: false, null: false)
      add(:payouts_enabled, :boolean, default: false, null: false)
      add(:details_submitted, :boolean, default: false, null: false)
      add(:disabled_reason, :string)
      add(:last_synced_at, :utc_datetime)
      add(:last_account_event_at, :utc_datetime)
      add(:deleted_at, :utc_datetime)
      add(:status, :string, default: "active", null: false)
      timestamps()
    end

    create(
      unique_index(:connect_accounts, [:stripe_account_id],
        where: "stripe_account_id IS NOT NULL"
      )
    )

    create(index(:connect_accounts, [:user_id], where: "deleted_at IS NULL"))
  end
end
