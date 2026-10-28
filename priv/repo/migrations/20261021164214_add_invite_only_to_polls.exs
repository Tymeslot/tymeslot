defmodule Tymeslot.Repo.Migrations.AddInviteOnlyToPolls do
  use Ecto.Migration

  @moduledoc """
  Adds `polls.invite_only`: whether only the people the host invited by email
  can vote. On such a poll the shared link no longer offers a way to ask for a
  voting link.

  Existing polls default to false and stay open to anyone holding their link,
  as they were.
  """

  def change do
    alter table(:polls) do
      # The default keeps every existing poll open to link requests, so it is
      # load-bearing. Postgres 11+ records a non-volatile default in the
      # catalogue instead of rewriting the table, so the lock covers a
      # catalogue update only.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :invite_only, :boolean, null: false, default: false
    end
  end
end
