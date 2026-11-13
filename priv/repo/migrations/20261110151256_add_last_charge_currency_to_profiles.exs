defmodule Tymeslot.Repo.Migrations.AddLastChargeCurrencyToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add(:last_charge_currency, :string, size: 3)
    end
  end
end
