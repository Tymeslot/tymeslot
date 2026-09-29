defmodule Tymeslot.Repo.Migrations.AddInvitedByToMeetingGuests do
  use Ecto.Migration

  @moduledoc """
  Adds `invited_by`: who put a guest on the meeting, so the guest's emails
  name the right person as the one who invited them.

  `"booker"` is a guest the person booking brought on the public page;
  `"organizer"` is one the host added (the Add Guests dialog, a Quick Add
  meeting's extra guests, a confirmed poll's participants). Nullable with no
  default, so the table is not rewritten. A row from before this column reads
  as nil, which the application treats as the booker: the wording guests have
  always received, and the email that row was already sent.
  """

  def change do
    alter table(:meeting_guests) do
      add :invited_by, :string
    end
  end
end
