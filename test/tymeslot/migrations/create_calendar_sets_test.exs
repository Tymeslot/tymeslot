defmodule Tymeslot.Migrations.CreateCalendarSetsTest do
  @moduledoc """
  The `create_calendar_sets` migration runs down and back up over existing
  preferences, which keep their values and start with no set, and the
  database itself holds a set to positions 1 to 9, one per position.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  # The generator picks the timestamp; the file name says it.
  @version "priv/repo/migrations/*_create_calendar_sets.exs"
           |> Path.wildcard()
           |> then(fn [path] ->
             path |> Path.basename() |> String.split("_", parts: 2) |> hd()
           end)
           |> String.to_integer()

  defp insert_set(user_id, position) do
    Repo.query!(
      "INSERT INTO calendar_sets (user_id, name, position, inserted_at, updated_at) VALUES ($1, 'Work', $2, now(), now())",
      [user_id, position]
    )
  end

  test "existing preferences keep their values and start with no set" do
    user = insert(:user)
    {:ok, _preferences} = CalendarPreferencesQueries.upsert(user.id, %{density: "compact"})

    MigrationRunner.rerun!(@version)

    assert %{rows: [["compact", nil]]} =
             Repo.query!(
               "SELECT density, active_calendar_set_id FROM calendar_preferences WHERE user_id = $1",
               [user.id]
             )
  end

  test "a position outside 1 to 9 is refused" do
    user = insert(:user)
    MigrationRunner.rerun!(@version)

    assert_raise Postgrex.Error, ~r/calendar_sets_position_range/, fn ->
      insert_set(user.id, 10)
    end
  end

  test "an organiser has one set per position" do
    user = insert(:user)
    MigrationRunner.rerun!(@version)
    insert_set(user.id, 1)

    assert_raise Postgrex.Error, ~r/calendar_sets_user_id_position_index/, fn ->
      insert_set(user.id, 1)
    end
  end
end
