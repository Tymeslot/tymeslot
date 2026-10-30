defmodule Tymeslot.Migrations.AddCalendarSyncStatusCheckToMeetingsTest do
  @moduledoc """
  Verifies `20261029124635_add_calendar_sync_status_check_to_meetings`
  backfills an out-of-vocabulary `calendar_sync_status` to NULL, leaves known
  values and NULL alone, and then closes the column with a CHECK constraint.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_124_635

  test "backfills an unknown sync status to NULL and re-closes the constraint" do
    stray = insert(:meeting)
    flagged = insert(:meeting, calendar_sync_status: :externally_modified)
    clean = insert(:meeting)

    MigrationRunner.down!(@version)
    set_raw_sync_status!(stray.id, "stale")

    MigrationRunner.up!(@version)

    assert %{calendar_sync_status: nil} = Repo.reload!(stray)
    assert %{calendar_sync_status: :externally_modified} = Repo.reload!(flagged)
    assert %{calendar_sync_status: nil} = Repo.reload!(clean)

    assert_raise Postgrex.Error, ~r/meetings_calendar_sync_status_must_be_known/, fn ->
      set_raw_sync_status!(clean.id, "stale")
    end
  end

  defp set_raw_sync_status!(id, status) do
    Repo.query!("UPDATE meetings SET calendar_sync_status = $1 WHERE id = $2", [
      status,
      UUID.dump!(id)
    ])
  end
end
