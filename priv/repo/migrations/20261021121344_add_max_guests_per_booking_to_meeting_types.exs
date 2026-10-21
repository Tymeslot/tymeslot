defmodule Tymeslot.Repo.Migrations.AddMaxGuestsPerBookingToMeetingTypes do
  @moduledoc """
  Lets a host limit how many guests one booking of a meeting type may bring
  (`max_guests_per_booking`). `NULL` keeps the overall limit every booking
  has today (`Tymeslot.Meetings.Guests.max_guests/0`), so existing rows are
  unchanged.

  This migration first ran under the version `20261014120000`. A database
  that ran it then already has the column, so it is added only if missing.
  """
  use Ecto.Migration

  def up do
    alter table(:meeting_types) do
      add_if_not_exists(:max_guests_per_booking, :integer)
    end
  end

  # Rolling back removes the column this migration added; nothing older reads it.
  def down do
    alter table(:meeting_types) do
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove_if_exists(:max_guests_per_booking, :integer)
    end
  end
end
