defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventRoleMigrationTest do
  @moduledoc """
  Covers the migration that adds `role`, the discriminator telling a busy
  interval apart from a calendar item in the event cache.

  The dirty seed cannot reach this: it carries no `provider_calendar_events`
  rows at all, so nothing there proves that a row cached before the column
  existed ends up on the item side. That default is load-bearing — get it wrong
  and every existing provider's cached events stop blocking time the moment the
  availability read starts filtering on it.

  The backfill is seeded with one opaque row and one transparent one because
  `role` and `transparency` are orthogonal, which is the interaction the
  migration's own documentation warns about: a transparent row still serves both
  reads, it simply blocks nothing once one of them has selected it.

  The migration is round-tripped through `Ecto.Migrator` from `priv` rather
  than replayed from a pasted copy of its SQL, so `up/0` meets the rows exactly
  as it will on an upgraded database. See `Tymeslot.Test.MigrationRunner`.

  Every test round-trips it, not only the backfill one, and that is not
  ceremony: the test database is already fully migrated, so a test that merely
  wrote a value would be asserting against whatever CHECK the database happens
  to carry rather than the one this file installs. Take the `rerun!/1` out of
  the vocabulary tests and they stay green against a migration that constrains
  nothing at all.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :calendar
  @moduletag :migrations

  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_819_170_109

  test "every row cached before the column existed is filed as serving both reads" do
    opaque = insert(:provider_calendar_event)
    transparent = insert(:provider_calendar_event, transparency: "transparent")

    MigrationRunner.rerun!(@version)

    assert role_of(opaque.id) == "both"
    assert role_of(transparent.id) == "both"
  end

  test "a value outside the three-way vocabulary is refused" do
    MigrationRunner.rerun!(@version)
    event = insert(:provider_calendar_event)

    assert_raise Postgrex.Error, ~r/provider_calendar_events_role_check/, fn ->
      set_role(event.id, "somewhen")
    end
  end

  test "each of the three roles is accepted" do
    MigrationRunner.rerun!(@version)
    event = insert(:provider_calendar_event)

    for role <- ~w[both display_only busy_only] do
      set_role(event.id, role)
      assert role_of(event.id) == role
    end
  end

  defp role_of(id) do
    %{rows: [[role]]} =
      Repo.query!("SELECT role FROM provider_calendar_events WHERE id = $1", [id])

    role
  end

  defp set_role(id, role) do
    Repo.query!("UPDATE provider_calendar_events SET role = $1 WHERE id = $2", [role, id])
  end
end
