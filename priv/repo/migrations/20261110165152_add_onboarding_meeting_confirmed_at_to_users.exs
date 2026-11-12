defmodule Tymeslot.Repo.Migrations.AddOnboardingMeetingConfirmedAtToUsers do
  @moduledoc """
  Records that a host got through the onboarding meeting step, which until now
  left no trace on the account, so the look and live steps can wait for it.

  The column only: the next migration backfills it in a transaction of its
  own, so this one holds its lock on `users` just long enough to add a column.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add(:onboarding_meeting_confirmed_at, :utc_datetime)
    end
  end
end
