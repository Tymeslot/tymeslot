defmodule Tymeslot.Repo.Migrations.AddBookingPagePublishedAtToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add(:booking_page_published_at, :utc_datetime)
    end
  end
end
