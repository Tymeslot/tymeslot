defmodule Tymeslot.Repo.Migrations.AddAttachmentsToMeetingTypes do
  use Ecto.Migration

  # Backing column for the `embeds_many(:attachments, ...)` on meeting types —
  # host-uploaded files (agenda/brief) surfaced on every booking.
  def change do
    alter table(:meeting_types) do
      add :attachments, {:array, :map}, null: false, default: []
    end
  end
end
