defmodule Tymeslot.Repo.Migrations.AddMaxGuestsPerBookingToMeetingTypes do
  @moduledoc """
  Lets a host limit how many guests one booking of a meeting type may bring
  (`max_guests_per_booking`). `NULL` keeps the overall limit every booking
  has today (`Tymeslot.Meetings.Guests.max_guests/0`), so existing rows are
  unchanged.
  """
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add(:max_guests_per_booking, :integer)
    end
  end
end
