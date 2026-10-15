defmodule Tymeslot.Repo.Migrations.AddVoteNotificationsToPolls do
  use Ecto.Migration

  @moduledoc """
  Lets a host be emailed about new votes on a poll, bundled into one email at
  most every quarter of an hour.

  `notify_on_vote` is the host's choice per poll. It defaults to off here, so
  polls that already exist stay as quiet as they were; the dashboard ticks it
  for a new poll. `vote_digest_sent_at` marks the last update the host got, so
  the next one names only who voted since.
  """

  def change do
    alter table(:polls) do
      add :notify_on_vote, :boolean, null: false, default: false
      add :vote_digest_sent_at, :utc_datetime
    end
  end
end
