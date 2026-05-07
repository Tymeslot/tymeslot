defmodule Tymeslot.Repo.Migrations.AddMarketingUnsubscribedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:marketing_unsubscribed_at, :utc_datetime)
    end
  end
end
