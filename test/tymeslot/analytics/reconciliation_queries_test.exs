defmodule Tymeslot.Analytics.ReconciliationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :analytics
  @moduletag :queries
  @moduletag :database

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Analytics.EventQueries
  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Analytics.ReconciliationQueries

  setup do
    now = DateTime.utc_now()

    %{
      user: insert(:user),
      from: DateTime.add(now, -3600, :second),
      to: DateTime.add(now, 3600, :second)
    }
  end

  defp insert_event(visitor_hash) do
    {:ok, _event} =
      EventQueries.insert(%{
        event_type: "booking_page_view",
        path: "/alice/intro",
        visitor_hash: visitor_hash
      })
  end

  defp insert_booking(user, visitor_hash, offset_min) do
    base = DateTime.utc_now(:second)

    insert(:meeting,
      organizer_user_id: user.id,
      start_time: DateTime.add(base, offset_min * 60, :minute),
      end_time: DateTime.add(base, offset_min * 60 + 30, :minute),
      visitor_hash: visitor_hash
    )
  end

  test "instance_totals counts visits, uniques, converting and untracked across the window",
       %{user: user, from: from, to: to} do
    # 3 page views from 2 distinct visitors.
    insert_event("v1")
    insert_event("v1")
    insert_event("v2")

    # v1 booked (tracked — a matching event exists), v3 booked (untracked — no
    # event with that hash), and one booking with no hash (excluded entirely).
    insert_booking(user, "v1", 1)
    insert_booking(user, "v3", 2)
    insert_booking(user, nil, 3)

    totals = ReconciliationQueries.instance_totals(from, to)

    assert totals.visits == 3
    assert totals.unique_visitors == 2
    assert totals.converting_visitors == 2
    assert totals.untracked_converting_visitors == 1
  end

  test "untracked count ignores events outside the window", %{user: user, from: from, to: to} do
    # v1 has a matching event but only OUTSIDE the window → still untracked.
    insert_booking(user, "v1", 1)

    old_event_at = DateTime.add(from, -1, :day)

    {:ok, _event} =
      %EventSchema{}
      |> EventSchema.changeset(%{
        event_type: "booking_page_view",
        path: "/alice/intro",
        visitor_hash: "v1"
      })
      |> Changeset.put_change(:inserted_at, old_event_at)
      |> Repo.insert()

    totals = ReconciliationQueries.instance_totals(from, to)

    assert totals.converting_visitors == 1
    assert totals.untracked_converting_visitors == 1
  end
end
