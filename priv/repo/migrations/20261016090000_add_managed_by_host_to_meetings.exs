defmodule Tymeslot.Repo.Migrations.AddManagedByHostToMeetings do
  use Ecto.Migration

  @moduledoc """
  Adds `meetings.managed_by_host`, set on a meeting confirmed from a poll.

  Such a meeting has no booker. Everyone who answered the poll is invited as
  a guest and answers yes or no like one, and only the host moves or cancels
  it. Existing meetings default to false and keep their booker.
  """

  def change do
    alter table(:meetings) do
      add :managed_by_host, :boolean, null: false, default: false
    end
  end
end
