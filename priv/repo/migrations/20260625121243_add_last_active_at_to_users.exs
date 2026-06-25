defmodule Tymeslot.Repo.Migrations.AddLastActiveAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:last_active_at, :utc_datetime)
    end
  end
end
