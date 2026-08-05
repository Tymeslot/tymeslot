defmodule Tymeslot.CalendarGrid.UserTimeFormatTest do
  @moduledoc """
  Covers `CalendarGrid.get_user_time_format/2`, the read path that email
  templates use when they hold only a user id.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid

  describe "get_user_time_format/2" do
    test "falls back to the language preset when the user has never chosen" do
      user = insert(:user)

      assert CalendarGrid.get_user_time_format(user.id, "de") == "24h"
      assert CalendarGrid.get_user_time_format(user.id, "en") == "12h"
    end

    test "returns the stored choice regardless of language" do
      user = insert(:user)
      {:ok, _prefs} = CalendarGrid.save_preferences(user.id, %{time_format: "12h"})

      assert CalendarGrid.get_user_time_format(user.id, "de") == "12h"
      assert CalendarGrid.get_user_time_format(user.id, "en") == "12h"
    end

    test "a stored 24h choice survives an English locale" do
      user = insert(:user)
      {:ok, _prefs} = CalendarGrid.save_preferences(user.id, %{time_format: "24h"})

      assert CalendarGrid.get_user_time_format(user.id, "en") == "24h"
    end

    test "changing other preferences does not silently pin the clock" do
      # upsert only replaces the keys it is given, so a user who changes their
      # week start must still be treated as having chosen no clock.
      user = insert(:user)
      {:ok, _prefs} = CalendarGrid.save_preferences(user.id, %{week_start_day: "sunday"})

      assert CalendarGrid.get_user_time_format(user.id, "de") == "24h"
    end

    test "falls back to the language preset when there is no user" do
      assert CalendarGrid.get_user_time_format(nil, "de") == "24h"
      assert CalendarGrid.get_user_time_format(nil, "en") == "12h"
    end
  end
end
