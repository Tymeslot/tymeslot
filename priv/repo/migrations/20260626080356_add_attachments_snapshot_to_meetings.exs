defmodule Tymeslot.Repo.Migrations.AddAttachmentsSnapshotToMeetings do
  use Ecto.Migration

  # Snapshot of the meeting type's attachments at booking time (mirrors
  # custom_fields_snapshot), so the files referenced in the calendar event and
  # confirmation email stay stable even if the meeting type is later edited.
  def change do
    alter table(:meetings) do
      add :attachments_snapshot, {:array, :map}, null: false, default: []
    end
  end
end
