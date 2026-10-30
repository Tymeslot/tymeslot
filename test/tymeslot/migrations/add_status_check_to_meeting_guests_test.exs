defmodule Tymeslot.Migrations.AddStatusCheckToMeetingGuestsTest do
  @moduledoc """
  Verifies `20261029111554_add_status_check_to_meeting_guests` backfills an
  out-of-vocabulary `status` to `pending`, leaves known values alone, and then
  closes the column with a CHECK constraint.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_111_554

  test "backfills an unknown status to pending and re-closes the constraint" do
    meeting = insert(:meeting)
    {:ok, [stray, declined]} = Guests.create_for_meeting(meeting.id, ~w(a@x.com b@x.com))
    {:ok, _declined} = Guests.record_rsvp(declined.rsvp_token, :declined)

    MigrationRunner.down!(@version)
    set_raw_status!(stray.id, "tentative")

    MigrationRunner.up!(@version)

    assert Repo.reload!(stray).status == :pending
    assert Repo.reload!(declined).status == :declined

    assert_raise Postgrex.Error, ~r/meeting_guests_status_must_be_known/, fn ->
      set_raw_status!(declined.id, "tentative")
    end
  end

  defp set_raw_status!(id, status) do
    Repo.query!("UPDATE meeting_guests SET status = $1 WHERE id = $2", [
      status,
      UUID.dump!(id)
    ])
  end
end
