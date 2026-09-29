defmodule Tymeslot.Repo.Migrations.AddOrganizerNoteToMeetings do
  use Ecto.Migration

  @moduledoc """
  Adds `organizer_note`: a note the organiser writes to the guest on a meeting
  they create themselves (Quick Add, or a confirmed poll's description).

  It is kept apart from `attendee_message`, which only ever holds what the
  attendee wrote, and from `description`, which carries the meeting type's
  description on a booking made through a page. Nullable with no default, so
  existing rows need nothing and the table is not rewritten.
  """

  def change do
    alter table(:meetings) do
      add :organizer_note, :text
    end
  end
end
