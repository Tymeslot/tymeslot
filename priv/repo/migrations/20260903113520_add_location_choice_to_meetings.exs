defmodule Tymeslot.Repo.Migrations.AddLocationChoiceToMeetings do
  @moduledoc """
  Records which of the meeting type's locations the booker chose.

  `location` already carries the display string, but it is prose: the email
  tree currently recovers the *kind* of location from it by matching the
  literals "Phone Call" and "In Person", which silently fails the moment a
  host writes their own label. `location_kind` states it instead, and
  `location_option_id` pins the choice to the option that produced it so a
  later edit to the meeting type cannot rewrite history.

  Both are nullable and stay so. A meeting booked before this shipped chose
  nothing, and `Tymeslot.Emails.Shared.BookingRequestLocation` keeps its
  literal-matching fallback for exactly those rows.
  """
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :location_kind, :string
      add :location_option_id, :string
    end
  end
end
