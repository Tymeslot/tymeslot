defmodule Tymeslot.Migrations.AddStatusCheckToMeetingsTest do
  @moduledoc """
  Verifies `20261029120342_add_status_check_to_meetings` backfills an
  out-of-vocabulary `status` to `cancelled` (stamping `cancelled_at` only
  where it is missing), leaves known values alone, and then closes the column
  with a CHECK constraint.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_120_342

  test "backfills an unknown status to cancelled and re-closes the constraint" do
    stamped_at = ~U[2026-01-02 03:04:05Z]
    stray = insert(:meeting, status: :confirmed)
    stamped_stray = insert(:meeting, status: :confirmed, cancelled_at: stamped_at)
    held = insert(:meeting, status: :awaiting_approval)

    MigrationRunner.down!(@version)
    set_raw_status!(stray.id, "booked")
    set_raw_status!(stamped_stray.id, "")

    MigrationRunner.up!(@version)

    assert %{status: :cancelled, cancelled_at: %DateTime{}} = Repo.reload!(stray)
    assert %{status: :cancelled, cancelled_at: ^stamped_at} = Repo.reload!(stamped_stray)
    assert %{status: :awaiting_approval, cancelled_at: nil} = Repo.reload!(held)

    assert_raise Postgrex.Error, ~r/meetings_status_must_be_known/, fn ->
      set_raw_status!(held.id, "booked")
    end
  end

  defp set_raw_status!(id, status) do
    Repo.query!("UPDATE meetings SET status = $1 WHERE id = $2", [status, UUID.dump!(id)])
  end
end
