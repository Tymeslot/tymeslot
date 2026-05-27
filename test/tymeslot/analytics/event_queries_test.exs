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

  describe "top_sources/3" do
    test "groups by utm_source, ordered by count desc", %{user: user} do
      insert_event(%{user_id: user.id, utm_source: "linkedin"})
      insert_event(%{user_id: user.id, utm_source: "linkedin"})
      insert_event(%{user_id: user.id, utm_source: "twitter"})
      insert_event(%{user_id: user.id, utm_source: nil})

      from = DateTime.add(DateTime.utc_now(), -3600, :second)
      to = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert [
               %{utm_source: "linkedin", visits: 2},
               %{utm_source: "twitter", visits: 1},
               %{utm_source: nil, visits: 1}
             ] = EventQueries.top_sources(user.id, from, to)
    end
  end
end
