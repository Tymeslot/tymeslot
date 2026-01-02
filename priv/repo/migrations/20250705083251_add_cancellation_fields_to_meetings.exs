defmodule Tymeslot.Repo.Migrations.AddCancellationFieldsToMeetings do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :cancelled_at, :utc_datetime
      add :cancellation_reason, :text
    end
  end
end
