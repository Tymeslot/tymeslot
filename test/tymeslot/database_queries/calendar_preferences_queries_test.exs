defmodule Tymeslot.DatabaseQueries.CalendarPreferencesQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.CalendarPreferencesQueries

  describe "get_or_create/1" do
    test "returns a new struct with defaults for user without preferences" do
      user = insert(:user)

      prefs = CalendarPreferencesQueries.get_or_create(user.id)

      assert prefs.user_id == user.id
      assert prefs.default_view == "week"
      assert prefs.hidden_integration_ids == []
      assert prefs.week_start_day == "monday"
      assert prefs.time_format == "12h"
      assert prefs.show_week_numbers == false
      assert prefs.show_weekends == true
      assert is_nil(prefs.id)
    end

    test "returns persisted preferences when they exist" do
      user = insert(:user)

      {:ok, _prefs} =
        CalendarPreferencesQueries.upsert(user.id, %{
          default_view: "day",
          time_format: "24h"
        })

      prefs = CalendarPreferencesQueries.get_or_create(user.id)

      refute is_nil(prefs.id)
      assert prefs.user_id == user.id
      assert prefs.default_view == "day"
      assert prefs.time_format == "24h"
    end
  end

  describe "upsert/2" do
    test "creates preferences for a new user" do
      user = insert(:user)

      assert {:ok, prefs} =
               CalendarPreferencesQueries.upsert(user.id, %{
                 default_view: "month",
                 time_format: "24h"
               })

      assert prefs.user_id == user.id
      assert prefs.default_view == "month"
      assert prefs.time_format == "24h"
    end

    test "updates preferences on second call" do
      user = insert(:user)

      {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{default_view: "week"})
      {:ok, prefs} = CalendarPreferencesQueries.upsert(user.id, %{default_view: "day"})

      assert prefs.default_view == "day"
    end

    test "validates default_view enum" do
      user = insert(:user)

      assert {:error, changeset} =
               CalendarPreferencesQueries.upsert(user.id, %{default_view: "invalid"})

      assert %{default_view: [_msg]} = errors_on(changeset)
    end

    test "validates week_start_day enum" do
      user = insert(:user)

      assert {:error, changeset} =
               CalendarPreferencesQueries.upsert(user.id, %{week_start_day: "wednesday"})

      assert %{week_start_day: [_msg]} = errors_on(changeset)
    end

    test "validates time_format enum" do
      user = insert(:user)

      assert {:error, changeset} =
               CalendarPreferencesQueries.upsert(user.id, %{time_format: "8h"})

      assert %{time_format: [_msg]} = errors_on(changeset)
    end

    test "preserves unspecified fields on update" do
      user = insert(:user)

      {:ok, _prefs} =
        CalendarPreferencesQueries.upsert(user.id, %{
          time_format: "24h",
          default_view: "month"
        })

      {:ok, _prefs} =
        CalendarPreferencesQueries.upsert(user.id, %{
          default_view: "day",
          time_format: "24h"
        })

      prefs = CalendarPreferencesQueries.get_or_create(user.id)

      assert prefs.default_view == "day"
      assert prefs.time_format == "24h"
    end
  end
end
