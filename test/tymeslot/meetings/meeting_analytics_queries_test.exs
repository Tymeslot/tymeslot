defmodule Tymeslot.Meetings.MeetingAnalyticsQueriesTest do
  @moduledoc false

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Meetings.MeetingAnalyticsQueries

  describe "count_bookings/3" do
    test "counts bookings for the organizer within the window" do
      user = insert(:user)
      other_user = insert(:user)
      now = DateTime.utc_now()
      from = DateTime.add(now, -3600, :second)
      to = DateTime.add(now, 3600, :second)
      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      insert_meeting_at(user.id, base)
      insert_meeting_at(user.id, DateTime.add(base, 3600, :second))
      insert_meeting_at(other_user.id, base)

      assert MeetingAnalyticsQueries.count_bookings(user.id, from, to) == 2
      assert MeetingAnalyticsQueries.count_bookings(other_user.id, from, to) == 1
    end

    test "excludes bookings outside the date range" do
      user = insert(:user)
      now = DateTime.utc_now()
      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      insert_meeting_at(user.id, base)

      past_from = DateTime.add(now, -7200, :second)
      past_to = DateTime.add(now, -3600, :second)

      assert MeetingAnalyticsQueries.count_bookings(user.id, past_from, past_to) == 0
    end

    test "returns 0 when the user has no bookings" do
      user = insert(:user)
      now = DateTime.utc_now()
      from = DateTime.add(now, -3600, :second)
      to = DateTime.add(now, 3600, :second)

      assert MeetingAnalyticsQueries.count_bookings(user.id, from, to) == 0
    end
  end

  describe "count_by_utm_source/3" do
    test "groups bookings by utm_source for the organizer" do
      user = insert(:user)
      now = DateTime.utc_now()
      from = DateTime.add(now, -3600, :second)
      to = DateTime.add(now, 3600, :second)
      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      insert_meeting_at(user.id, base, utm_source: "linkedin")
      insert_meeting_at(user.id, DateTime.add(base, 3600, :second), utm_source: "linkedin")
      insert_meeting_at(user.id, DateTime.add(base, 7200, :second), utm_source: "twitter")

      result = MeetingAnalyticsQueries.count_by_utm_source(user.id, from, to)

      linkedin = Enum.find(result, &(&1.utm_source == "linkedin"))
      twitter = Enum.find(result, &(&1.utm_source == "twitter"))

      assert linkedin.bookings == 2
      assert twitter.bookings == 1
    end

    test "does not return a row for nil utm_source (direct/unknown)" do
      user = insert(:user)
      now = DateTime.utc_now()
      from = DateTime.add(now, -3600, :second)
      to = DateTime.add(now, 3600, :second)
      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      insert_meeting_at(user.id, base, utm_source: nil)
      insert_meeting_at(user.id, DateTime.add(base, 3600, :second), utm_source: "linkedin")

      result = MeetingAnalyticsQueries.count_by_utm_source(user.id, from, to)

      assert length(result) == 1
      assert hd(result).utm_source == "linkedin"
    end

    test "returns only rows for the given organizer" do
      user = insert(:user)
      other_user = insert(:user)
      now = DateTime.utc_now()
      from = DateTime.add(now, -3600, :second)
      to = DateTime.add(now, 3600, :second)
      base = DateTime.truncate(DateTime.add(now, 1, :day), :second)

      insert_meeting_at(user.id, base, utm_source: "linkedin")
      insert_meeting_at(other_user.id, base, utm_source: "twitter")

      result = MeetingAnalyticsQueries.count_by_utm_source(user.id, from, to)

      assert length(result) == 1
      assert hd(result).utm_source == "linkedin"
    end
  end

  defp insert_meeting_at(organizer_id, start_time, extra \\ []) do
    attrs =
      [
        organizer_user_id: organizer_id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 60, :minute)
      ] ++ extra

    insert(:meeting, attrs)
  end
end
