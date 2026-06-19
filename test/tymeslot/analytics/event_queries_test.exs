defmodule Tymeslot.Analytics.EventQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Analytics.EventQueries
  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Factory
  alias Tymeslot.Repo

  setup do
    user = Factory.insert(:user)
    %{user: user}
  end

  defp insert_event(attrs) do
    base = %{
      event_type: "booking_page_view",
      path: "/x",
      visitor_hash: "h",
      tracking_params: %{}
    }

    {:ok, event} =
      %EventSchema{}
      |> EventSchema.changeset(Map.merge(base, attrs))
      |> Repo.insert()

    event
  end

  defp insert_event_at(attrs, inserted_at) do
    base = %{
      event_type: "booking_page_view",
      path: "/x",
      visitor_hash: "h",
      tracking_params: %{},
      inserted_at: inserted_at
    }

    Repo.insert!(struct(EventSchema, Map.merge(base, attrs)))
  end

  describe "count_visits/3" do
    test "counts events for user in the given window", %{user: user} do
      other_user = Factory.insert(:user)
      insert_event(%{user_id: user.id})
      insert_event(%{user_id: user.id})
      insert_event(%{user_id: other_user.id})

      from = DateTime.add(DateTime.utc_now(), -3600, :second)
      to = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert EventQueries.count_visits(user.id, from, to) == 2
    end

    test "respects the date range", %{user: user} do
      insert_event(%{user_id: user.id})

      past_from = DateTime.add(DateTime.utc_now(), -7200, :second)
      past_to = DateTime.add(DateTime.utc_now(), -3600, :second)

      assert EventQueries.count_visits(user.id, past_from, past_to) == 0
    end
  end

  describe "count_unique_visitors/3" do
    test "counts distinct visitor_hash values", %{user: user} do
      insert_event(%{user_id: user.id, visitor_hash: "a"})
      insert_event(%{user_id: user.id, visitor_hash: "a"})
      insert_event(%{user_id: user.id, visitor_hash: "b"})

      from = DateTime.add(DateTime.utc_now(), -3600, :second)
      to = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert EventQueries.count_unique_visitors(user.id, from, to) == 2
    end
  end

  describe "top_sources_with_unique/3" do
    test "groups by utm_source with unique visitor counts, ordered by visits desc", %{
      user: user
    } do
      insert_event(%{user_id: user.id, utm_source: "linkedin", visitor_hash: "a"})
      insert_event(%{user_id: user.id, utm_source: "linkedin", visitor_hash: "b"})
      insert_event(%{user_id: user.id, utm_source: "twitter", visitor_hash: "c"})
      insert_event(%{user_id: user.id, utm_source: nil, visitor_hash: "d"})

      from = DateTime.add(DateTime.utc_now(), -3600, :second)
      to = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert [
               %{utm_source: "linkedin", visits: 2, unique_visitors: 2},
               %{utm_source: "twitter", visits: 1, unique_visitors: 1}
             ] = EventQueries.top_sources_with_unique(user.id, from, to)
    end

    test "does not return a row for nil utm_source", %{user: user} do
      insert_event(%{user_id: user.id, utm_source: nil})
      insert_event(%{user_id: user.id, utm_source: nil})

      from = DateTime.add(DateTime.utc_now(), -3600, :second)
      to = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert EventQueries.top_sources_with_unique(user.id, from, to) == []
    end
  end

  describe "visits_by_day/4" do
    test "groups visits by day in ascending order", %{user: user} do
      today = DateTime.utc_now()
      yesterday = DateTime.add(today, -86_400, :second)

      insert_event_at(%{user_id: user.id}, yesterday)
      insert_event_at(%{user_id: user.id}, yesterday)
      insert_event_at(%{user_id: user.id}, today)

      from = DateTime.add(today, -2 * 86_400, :second)
      to = DateTime.add(today, 3600, :second)

      result = EventQueries.visits_by_day(user.id, from, to, "Etc/UTC")

      assert length(result) == 2
      [first, second] = result
      assert first.day == DateTime.to_date(yesterday)
      assert first.visits == 2
      assert second.day == DateTime.to_date(today)
      assert second.visits == 1
    end

    test "excludes events outside the window", %{user: user} do
      today = DateTime.utc_now()
      two_days_ago = DateTime.add(today, -2 * 86_400, :second)

      insert_event_at(%{user_id: user.id}, two_days_ago)
      insert_event_at(%{user_id: user.id}, today)

      from = DateTime.add(today, -3600, :second)
      to = DateTime.add(today, 3600, :second)

      result = EventQueries.visits_by_day(user.id, from, to, "Etc/UTC")

      assert length(result) == 1
      [only] = result
      assert only.day == DateTime.to_date(today)
      assert only.visits == 1
    end

    test "buckets events by the organizer's local day, not UTC", %{user: user} do
      # 02:00 UTC on 2026-06-15 is 22:00 on 2026-06-14 in America/New_York (UTC-4 in June).
      utc_dt = DateTime.from_naive!(~N[2026-06-15 02:00:00.000000], "Etc/UTC")
      insert_event_at(%{user_id: user.id}, utc_dt)

      from = DateTime.from_naive!(~N[2026-06-10 00:00:00], "Etc/UTC")
      to = DateTime.from_naive!(~N[2026-06-20 00:00:00], "Etc/UTC")

      assert [%{day: ~D[2026-06-14], visits: 1}] =
               EventQueries.visits_by_day(user.id, from, to, "America/New_York")

      # The same instant buckets to 2026-06-15 under UTC.
      assert [%{day: ~D[2026-06-15], visits: 1}] =
               EventQueries.visits_by_day(user.id, from, to, "Etc/UTC")
    end
  end
end
