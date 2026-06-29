defmodule Tymeslot.Integrations.Calendar.CalendarPreferencesQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

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

    test "persists the agenda view as a default_view" do
      user = insert(:user)

      assert {:ok, prefs} =
               CalendarPreferencesQueries.upsert(user.id, %{default_view: "agenda"})

      assert prefs.default_view == "agenda"
      assert CalendarPreferencesQueries.get_or_create(user.id).default_view == "agenda"
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

    test "preserves unspecified fields on partial update" do
      user = insert(:user)

      {:ok, _prefs} =
        CalendarPreferencesQueries.upsert(user.id, %{
          default_view: "month",
          time_format: "24h",
          week_start_day: "sunday",
          show_week_numbers: true,
          show_weekends: false,
          hidden_integration_ids: [1, 2, 3]
        })

      # Partial update touching only hidden_integration_ids must not
      # reset the other columns to their schema defaults.
      {:ok, _prefs} =
        CalendarPreferencesQueries.upsert(user.id, %{hidden_integration_ids: [4]})

      prefs = CalendarPreferencesQueries.get_or_create(user.id)

      assert prefs.hidden_integration_ids == [4]
      assert prefs.default_view == "month"
      assert prefs.time_format == "24h"
      assert prefs.week_start_day == "sunday"
      assert prefs.show_week_numbers == true
      assert prefs.show_weekends == false
    end
  end
end
