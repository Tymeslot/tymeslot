defmodule Tymeslot.Repo.Migrations.AddShowAsFreeToMeetings do
  use Ecto.Migration

  # Snapshot of the meeting type's `show_as_free` setting at booking time
  # (mirrors `custom_fields_snapshot`), so the transparency written to the
  # host's calendar is stable even if the meeting type is later changed.
  def change do
    alter table(:meetings) do
      add :show_as_free, :boolean, null: false, default: false
    end
  end
end
