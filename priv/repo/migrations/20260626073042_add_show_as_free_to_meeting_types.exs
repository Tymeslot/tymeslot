defmodule Tymeslot.Repo.Migrations.AddShowAsFreeToMeetingTypes do
  use Ecto.Migration

  # Host opt-in: when set, bookings of this meeting type are written to the
  # connected calendar as free/transparent (TRANSP:TRANSPARENT, Google
  # transparency=transparent, Outlook showAs=free) so they do not block the
  # host's availability. Defaults to false — existing rows remain busy/opaque.
  def change do
    alter table(:meeting_types) do
      add :show_as_free, :boolean, null: false, default: false
    end
  end
end
