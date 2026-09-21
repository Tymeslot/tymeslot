defmodule Tymeslot.Repo.Migrations.AddRemindersSentToMeetingGuests do
  use Ecto.Migration

  @moduledoc """
  Records which reminder configurations a guest has already been emailed for.

  A meeting can carry several reminder offsets, so `confirmation_sent_at` alone
  cannot express "sent for the 24 h reminder but not the 1 h one". This mirrors
  `meetings.reminders_sent`, kept per guest row so that N guests do not
  serialise on the meeting row.

  Nullable with no default, exactly like the column it mirrors: existing rows
  read as `nil`, which `List.wrap/1` treats as "nothing sent yet", so no
  backfill is needed and no guest is skipped for a reminder they never got.
  """

  def change do
    alter table(:meeting_guests) do
      add :reminders_sent, {:array, :map}
    end
  end
end
