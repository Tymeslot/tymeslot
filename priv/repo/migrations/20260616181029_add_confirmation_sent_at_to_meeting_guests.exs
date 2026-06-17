defmodule Tymeslot.Repo.Migrations.AddConfirmationSentAtToMeetingGuests do
  use Ecto.Migration

  def change do
    alter table(:meeting_guests) do
      add(:confirmation_sent_at, :utc_datetime, null: true)
    end
  end
end
