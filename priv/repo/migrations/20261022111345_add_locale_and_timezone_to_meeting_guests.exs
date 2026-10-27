defmodule Tymeslot.Repo.Migrations.AddLocaleAndTimezoneToMeetingGuests do
  use Ecto.Migration

  # A guest's own language and timezone, for a guest who came with them (a
  # poll participant the host confirmed a meeting for). Nullable with no
  # default: every existing guest, and every guest added on an ordinary
  # booking, keeps reading the meeting's attendee language and timezone.
  def change do
    alter table(:meeting_guests) do
      add :locale, :string
      add :timezone, :string
    end
  end
end
