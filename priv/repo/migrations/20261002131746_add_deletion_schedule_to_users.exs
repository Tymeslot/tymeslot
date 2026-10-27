defmodule Tymeslot.Repo.Migrations.AddDeletionScheduleToUsers do
  @moduledoc """
  Records a self-service or operator account deletion: when it was asked for,
  and when the account is to be deleted. Both stay NULL for every account
  that is not pending deletion, which is every existing row.
  """

  use Ecto.Migration

  def change do
    alter table(:users) do
      add :deletion_requested_at, :utc_datetime
      add :deletion_scheduled_at, :utc_datetime
    end
  end
end
