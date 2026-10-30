defmodule Tymeslot.Migrations.AddLocationKindCheckToMeetingsTest do
  @moduledoc """
  Verifies `20261029131130_add_location_kind_check_to_meetings` backfills an
  out-of-vocabulary `location_kind` to NULL, leaves known values and NULL
  alone, and then closes the column with a CHECK constraint.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_029_131_130

  test "backfills an unknown location kind to NULL and re-closes the constraint" do
    stray = insert(:meeting, location_kind: :phone)
    known = insert(:meeting, location_kind: :in_person)
    legacy = insert(:meeting, location_kind: nil)

    MigrationRunner.down!(@version)
    set_raw_location_kind!(stray.id, "carrier_pigeon")

    MigrationRunner.up!(@version)

    assert %{location_kind: nil} = Repo.reload!(stray)
    assert %{location_kind: :in_person} = Repo.reload!(known)
    assert %{location_kind: nil} = Repo.reload!(legacy)

    assert_raise Postgrex.Error, ~r/meetings_location_kind_must_be_known/, fn ->
      set_raw_location_kind!(legacy.id, "carrier_pigeon")
    end
  end

  defp set_raw_location_kind!(id, kind) do
    Repo.query!("UPDATE meetings SET location_kind = $1 WHERE id = $2", [kind, UUID.dump!(id)])
  end
end
