defmodule Tymeslot.Repo.Migrations.AddConfirmationToPollParticipants do
  use Ecto.Migration

  @moduledoc """
  Adds email confirmation to poll participants.

  A participant now gets their personal voting link only by email, and their
  responses count from the first time they save them through it. `link_sent_at`
  throttles and expires those links; `confirmed_at` marks the participant whose
  responses count.

  Everyone already on a poll registered under the old rules and may have voted,
  so they are confirmed here rather than dropped from polls that are still
  running. Their `?p=` links keep working.
  """

  def up do
    alter table(:poll_participants) do
      add :confirmed_at, :utc_datetime
      add :link_sent_at, :utc_datetime
    end

    execute("UPDATE poll_participants SET confirmed_at = COALESCE(voted_at, inserted_at)")
  end

  def down do
    alter table(:poll_participants) do
      remove :confirmed_at
      remove :link_sent_at
    end
  end
end
