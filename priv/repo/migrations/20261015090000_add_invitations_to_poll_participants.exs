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
      # Dropping NOT NULL is a catalogue-only change: no rewrite, no scan.
      # excellent_migrations:safety-assured-for-next-line column_type_changed
      modify :name, :string, null: true
      add :invited_at, :utc_datetime
    end
  end

  # Unnamed invitees fall back to their address so the constraint can return.
  # The rollback only ever runs deliberately, on a small table (a row per
  # person on a poll), and removing what `up` added is its whole point.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file not_null_added
  # excellent_migrations:safety-assured-for-this-file column_removed
  def down do
    execute("UPDATE poll_participants SET name = email WHERE name IS NULL")

    alter table(:poll_participants) do
      # excellent_migrations:safety-assured-for-next-line column_type_changed
      modify :name, :string, null: false
      remove :invited_at
    end
  end
end
