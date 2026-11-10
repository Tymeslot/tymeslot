defmodule Tymeslot.Repo.Migrations.AddBookingLinkFirstSharedAtToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add(:booking_link_first_shared_at, :utc_datetime)
    end
  end
end
