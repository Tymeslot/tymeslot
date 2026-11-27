defmodule Tymeslot.Repo.Migrations.AddRedirectSettingsToMeetingTypes do
  @moduledoc """
  Adds where a booker is sent once a new booking of the meeting type is
  made: `redirect_url`, an absolute http(s) address the host chose (NULL
  keeps the booker on Tymeslot's own confirmation), and
  `redirect_pass_details`, whether the booking's details travel along as
  query parameters (`Tymeslot.Bookings.RedirectParams`).

  `text` rather than `varchar(255)`: an address with a tracking query easily
  passes 255 characters. The schema caps it at 2048
  (`Tymeslot.MeetingTypes.RedirectUrl`).
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # A constant default is a catalogue-only change on Postgres 11+, and existing
  # rows read false: no details are passed until a host opts in.
  def change do
    alter table(:meeting_types) do
      add(:redirect_url, :text)
      add(:redirect_pass_details, :boolean, null: false, default: false)
    end
  end
end
