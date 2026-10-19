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

  test "untracked count ignores events outside the window when same-day tracking is active",
       %{user: user, from: from, to: to} do
    # v1 has a matching event only OUTSIDE the window. A second visitor (v2)
    # has a same-day event, proving tracking was active today. v1 is still
    # counted as untracked because there is no same-day event for v1.
    insert_booking(user, "v1", 1)
    insert_event("v2")

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

  test "cross-day booking (page-view on prior day) is not counted as untracked when no same-day events exist",
       %{user: user, from: from, to: to} do
    # Simulates a visitor who browsed on a prior UTC day (different salt →
    # different hash) and booked today. Because no same-day events exist, we
    # cannot verify whether the booking was tracked or not, so it must NOT be
    # counted as untracked (unverifiable, not lost).
    insert_booking(user, "v1", 1)

    prior_day_at = DateTime.add(DateTime.utc_now(), -1, :day)

    # Event on a prior day — same visitor hash value is used here to represent
    # "what the hash would have been yesterday" (in practice the salt differs,
    # but from the query's perspective there is simply no event on today's date).
    {:ok, _event} =
      %EventSchema{}
      |> EventSchema.changeset(%{
        event_type: "booking_page_view",
        path: "/alice/intro",
        visitor_hash: "v1"
      })
      |> Changeset.put_change(:inserted_at, prior_day_at)
      |> Repo.insert()

    totals = ReconciliationQueries.instance_totals(from, to)

    assert totals.converting_visitors == 1
    # No same-day events → unverifiable → excluded from untracked numerator.
    assert totals.untracked_converting_visitors == 0
  end

  test "same-day page-view is found and booking is not counted as untracked",
       %{user: user, from: from, to: to} do
    # Both event and booking on the same UTC day → salt matches → correctly
    # counted as tracked.
    insert_event("v1")
    insert_booking(user, "v1", 1)

    totals = ReconciliationQueries.instance_totals(from, to)

    assert totals.converting_visitors == 1
    assert totals.untracked_converting_visitors == 0
  end

  describe "same-day matching at the UTC day boundaries" do
    # The booking day under test, and the window that covers it.
    @day ~D[2026-03-10]
    @day_start DateTime.new!(@day, ~T[00:00:00], "Etc/UTC")
    @day_end DateTime.new!(@day, ~T[23:59:59], "Etc/UTC")

    defp at(date, time), do: DateTime.new!(date, time, "Etc/UTC")

    defp insert_event_at(visitor_hash, inserted_at) do
      {:ok, _event} =
        %EventSchema{}
        |> EventSchema.changeset(%{
          event_type: "booking_page_view",
          path: "/alice/intro",
          visitor_hash: visitor_hash
        })
        |> Changeset.put_change(:inserted_at, inserted_at)
        |> Repo.insert()
    end

    defp insert_booking_at(user, visitor_hash, inserted_at) do
      # A distinct start time per booking keeps the organiser's one-meeting-per-
      # slot constraint satisfied; only `inserted_at` matters here.
      start_time = DateTime.add(@day_start, System.unique_integer([:positive]), :hour)

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute),
        visitor_hash: visitor_hash,
        inserted_at: inserted_at
      )
    end

    test "events at the first and last instant of the booking day count as same-day",
         %{user: user} do
      # Bookings mid-day and at both ends of the day, each matched by an event
      # at the opposite extreme of that same UTC day.
      insert_booking_at(user, "first", at(@day, ~T[12:00:00]))
      insert_event_at("first", at(@day, ~T[00:00:00.000000]))

      insert_booking_at(user, "last", at(@day, ~T[12:00:00]))
      insert_event_at("last", at(@day, ~T[23:59:59.999999]))

      insert_booking_at(user, "late_booking", at(@day, ~T[23:59:59]))
      insert_event_at("late_booking", at(@day, ~T[00:00:00.000000]))

      insert_booking_at(user, "early_booking", at(@day, ~T[00:00:00]))
      insert_event_at("early_booking", at(@day, ~T[23:59:59.999999]))

      totals = ReconciliationQueries.instance_totals(@day_start, @day_end)

      assert totals.converting_visitors == 4
      assert totals.untracked_converting_visitors == 0
    end

    test "events at the neighbouring midnights do not count as same-day", %{user: user} do
      # An unrelated event mid-day proves tracking was active on the booking day,
      # so a booking without a same-day match is counted as untracked.
      insert_event_at("other", at(@day, ~T[12:00:00.000000]))

      insert_booking_at(user, "next_midnight", at(@day, ~T[23:59:59]))
      insert_event_at("next_midnight", at(Date.add(@day, 1), ~T[00:00:00.000000]))

      insert_booking_at(user, "previous_instant", at(@day, ~T[00:00:00]))
      insert_event_at("previous_instant", at(Date.add(@day, -1), ~T[23:59:59.999999]))

      totals = ReconciliationQueries.instance_totals(@day_start, @day_end)

      assert totals.converting_visitors == 2
      assert totals.untracked_converting_visitors == 2
    end
  end
end
