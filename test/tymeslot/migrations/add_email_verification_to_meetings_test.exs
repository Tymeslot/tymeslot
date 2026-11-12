defmodule Tymeslot.Migrations.AddEmailVerificationToMeetingsTest do
  @moduledoc """
  Verifies `20261112193235_add_email_verification_to_meetings` widens the
  status check to admit `awaiting_verification`, and that its `down` expires
  any such row before restoring the narrower check.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_112_193_235

  test "the status check admits awaiting_verification" do
    held = insert(:meeting, status: :confirmed)

    # `up` has already run for the test database: roll it back, then replay it.
    MigrationRunner.down!(@version)

    assert_raise Postgrex.Error, ~r/meetings_status_must_be_known/, fn ->
      set_raw_status!(held.id, "awaiting_verification")
    end

    MigrationRunner.up!(@version)
    set_raw_status!(held.id, "awaiting_verification")
    assert %{status: :awaiting_verification} = Repo.reload!(held)

    MigrationRunner.down!(@version)

    # The columns are gone after `down`, so read the row raw.
    assert %{rows: [["expired", %NaiveDateTime{}]]} =
             Repo.query!("SELECT status, cancelled_at FROM meetings WHERE id = $1", [
               UUID.dump!(held.id)
             ])

    assert_raise Postgrex.Error, ~r/meetings_status_must_be_known/, fn ->
      set_raw_status!(held.id, "awaiting_verification")
    end
  end

  defp set_raw_status!(id, status) do
    Repo.query!("UPDATE meetings SET status = $1 WHERE id = $2", [status, UUID.dump!(id)])
  end
end
