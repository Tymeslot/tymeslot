defmodule Tymeslot.Migrations.AddEmailVerificationToMeetingsTest do
  @moduledoc """
  Verifies `20261112193235_add_email_verification_to_meetings` widens the
  status check to admit `awaiting_verification`, and that its `down` deletes
  every never-verified booking (held or released) before restoring the
  narrower check, so the old code never shows the organiser a booking that
  was never confirmed.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_112_193_235

  test "the status check admits awaiting_verification" do
    held = insert(:meeting, status: :confirmed)
    other = insert(:meeting, status: :confirmed)

    # `up` has already run for the test database: roll it back, then replay it.
    MigrationRunner.down!(@version)

    assert_raise Postgrex.Error, ~r/meetings_status_must_be_known/, fn ->
      set_raw_status!(held.id, "awaiting_verification")
    end

    MigrationRunner.up!(@version)
    set_raw_status!(held.id, "awaiting_verification")
    assert %{status: :awaiting_verification} = Repo.reload!(held)

    MigrationRunner.down!(@version)

    # A held row without a deadline cannot be written by the domain, but
    # `down` must not trip over one: it goes too.
    assert surviving_ids() == [other.id]

    assert_raise Postgrex.Error, ~r/meetings_status_must_be_known/, fn ->
      set_raw_status!(other.id, "awaiting_verification")
    end
  end

  test "down deletes every never-verified booking and keeps the rest" do
    now = DateTime.utc_now(:second)

    held = insert(:awaiting_verification_meeting)

    released =
      insert(:meeting, status: :expired, verification_deadline_at: now, cancelled_at: now)

    verified =
      insert(:meeting, status: :confirmed, verification_deadline_at: now, email_verified_at: now)

    ungated = insert(:meeting, status: :confirmed)

    {:ok, guest} = GuestQueries.insert_guest(%{meeting_id: held.id, email: "guest@example.com"})

    MigrationRunner.down!(@version)

    # The columns are gone after `down`, so read the rows raw.
    assert surviving_ids() == Enum.sort([verified.id, ungated.id])
    refute released.id in surviving_ids()

    assert %{rows: [[0]]} =
             Repo.query!("SELECT count(*) FROM meeting_guests WHERE id = $1", [
               UUID.dump!(guest.id)
             ])
  end

  defp surviving_ids do
    %{rows: rows} = Repo.query!("SELECT id FROM meetings")
    rows |> Enum.map(fn [id] -> UUID.load!(id) end) |> Enum.sort()
  end

  defp set_raw_status!(id, status) do
    Repo.query!("UPDATE meetings SET status = $1 WHERE id = $2", [status, UUID.dump!(id)])
  end
end
