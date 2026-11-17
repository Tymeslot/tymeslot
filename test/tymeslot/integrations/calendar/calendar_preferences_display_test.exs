defmodule Tymeslot.Integrations.Calendar.CalendarPreferencesDisplayTest do
  @moduledoc """
  The preferences the calendar's display stores: density, the folded night
  and focus mode. There is one calendar, so no preference picks it.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesSchema
  alias Tymeslot.Repo

  test "a user who never chose gets comfortable density, the night folded and no focus mode" do
    user = insert(:user)

    prefs = CalendarPreferencesQueries.get_or_create(user.id)

    assert {prefs.density, prefs.fold_night, prefs.focus_mode} == {"comfortable", true, false}
  end

  test "stored choices are read back" do
    user = insert(:user)

    {:ok, _prefs} =
      CalendarPreferencesQueries.upsert(user.id, %{
        density: "compact",
        fold_night: false,
        focus_mode: true
      })

    prefs = CalendarPreferencesQueries.get_or_create(user.id)

    assert {prefs.density, prefs.fold_night, prefs.focus_mode} == {"compact", false, true}
  end

  test "no preference picks a calendar surface" do
    refute :redesign_enabled in CalendarPreferencesSchema.__schema__(:fields)

    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'calendar_preferences'"
      )

    columns = List.flatten(rows)
    assert "focus_mode" in columns
    refute "redesign_enabled" in columns
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
