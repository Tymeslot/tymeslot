defmodule Tymeslot.Integrations.Calendar.CalendarPreferencesRedesignTest do
  @moduledoc """
  The preferences the redesigned calendar stores: the switch between the two
  calendar surfaces, density, the folded night and focus mode.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema

  test "a user who never chose keeps the old calendar, comfortable density and the night folded" do
    user = insert(:user)

    prefs = CalendarPreferencesQueries.get_or_create(user.id)

    assert prefs.redesign_enabled == false
    assert prefs.density == "comfortable"
    assert prefs.fold_night == true
    assert prefs.focus_mode == false
  end

  test "stored choices are read back" do
    user = insert(:user)

    {:ok, _prefs} =
      CalendarPreferencesQueries.upsert(user.id, %{
        redesign_enabled: true,
        density: "compact",
        fold_night: false,
        focus_mode: true
      })

    prefs = CalendarPreferencesQueries.get_or_create(user.id)

    assert {prefs.redesign_enabled, prefs.density, prefs.fold_night, prefs.focus_mode} ==
             {true, "compact", false, true}
  end

  test "switching surfaces leaves the other preferences alone" do
    user = insert(:user)

    {:ok, _prefs} =
      CalendarPreferencesQueries.upsert(user.id, %{density: "compact", week_start_day: "sunday"})

    {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{redesign_enabled: true})

    prefs = CalendarPreferencesQueries.get_or_create(user.id)

    assert prefs.redesign_enabled
    assert prefs.density == "compact"
    assert prefs.week_start_day == "sunday"
  end

  test "rejects a density the grid cannot draw" do
    changeset =
      CalendarPreferencesSchema.changeset(%CalendarPreferencesSchema{}, %{
        user_id: 1,
        density: "cosy"
      })

    assert %{density: [_message]} = errors_on(changeset)
  end
end
