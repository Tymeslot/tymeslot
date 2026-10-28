defmodule Tymeslot.Repo.Migrations.AddReminderConfigToPolls do
  use Ecto.Migration

  @moduledoc """
  Lets the host choose when a poll's participants are reminded before its
  voting deadline, as a meeting type chooses its booking reminders.

  Nullable with no backfill: a poll without a configuration keeps the one
  reminder every poll had so far, a day before the deadline (see
  `Tymeslot.Polls.PollSchema.reminders/1`). An empty list means none.
  """

  def change do
    alter table(:polls) do
      add :reminder_config, {:array, :map}
    end
  end
end
