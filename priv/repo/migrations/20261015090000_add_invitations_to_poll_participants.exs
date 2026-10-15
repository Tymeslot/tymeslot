defmodule Tymeslot.Repo.Migrations.AddInvitationsToPollParticipants do
  use Ecto.Migration

  @moduledoc """
  Lets a host invite people to a poll by address.

  An invitee may exist without a name, which they give the first time they
  vote, so `name` becomes nullable. `invited_at` marks who the host invited:
  only a poll with invitees knows who "everyone" is, so only such a poll
  tells the host when everyone has voted.
  """

  def up do
    alter table(:poll_participants) do
      modify :name, :string, null: true
      add :invited_at, :utc_datetime
    end
  end

  # Unnamed invitees fall back to their address so the constraint can return.
  def down do
    execute("UPDATE poll_participants SET name = email WHERE name IS NULL")

    alter table(:poll_participants) do
      modify :name, :string, null: false
      remove :invited_at
    end
  end
end
