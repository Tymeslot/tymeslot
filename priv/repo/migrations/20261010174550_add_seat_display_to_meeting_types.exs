defmodule Tymeslot.Repo.Migrations.AddSeatDisplayToMeetingTypes do
  @moduledoc """
  Lets an organiser choose what a group meeting type's booking page says
  about the spots left on each time.

    * `show_seat_availability`: the traffic-light marker on every slot.
      Existing rows get `true`, so their slots keep their colours.
    * `last_spots_threshold`: show the exact count only once that many spots
      or fewer are left; `NULL` never shows it. Existing rows get `NULL`, so
      the exact count they used to show on every slot goes away.

  Neither column means anything for a one-to-one type.
  """
  use Ecto.Migration

  # The default is a constant, which PostgreSQL 11 and later record in the
  # catalogue without rewriting the table.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default

  def change do
    alter table(:meeting_types) do
      add(:show_seat_availability, :boolean, null: false, default: true)
      add(:last_spots_threshold, :integer)
    end
  end
end
