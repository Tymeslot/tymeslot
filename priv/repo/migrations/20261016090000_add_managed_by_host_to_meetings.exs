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
      # The default keeps every existing meeting with its booker, so it is
      # load-bearing. Postgres 11+ records a non-volatile default in the
      # catalogue instead of rewriting the table, so the lock covers a
      # catalogue update only.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :managed_by_host, :boolean, null: false, default: false
    end
  end
end
