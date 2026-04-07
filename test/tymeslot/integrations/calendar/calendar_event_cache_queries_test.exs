defmodule Tymeslot.Integrations.Calendar.CalendarEventCacheQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.CalendarEventCacheQueries
  alias Tymeslot.Integrations.Calendar.CalendarEventCacheSchema

  defp build_event_attrs(integration, overrides) do
    now = DateTime.utc_now(:second)

    Map.merge(
      %{
        uid: "event-#{System.unique_integer([:positive])}",
        calendar_integration_id: integration.id,
        start_at: now,
        end_at: DateTime.add(now, 3600, :second),
        title: "Test Event"
      },
      overrides
    )
  end

  describe "list_for_range/3" do
    test "returns empty list for empty integration_ids" do
      assert [] =
               CalendarEventCacheQueries.list_for_range(
                 [],
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2026-12-31 23:59:59Z]
               )
    end

    test "returns events overlapping the range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      range_start = ~U[2026-06-01 00:00:00Z]
      range_end = ~U[2026-06-30 23:59:59Z]

      # Before range
      insert(:calendar_event_cache,
        calendar_integration: integration,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z]
      )

      # Overlapping range
      overlapping =
        insert(:calendar_event_cache,
          calendar_integration: integration,
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z]
        )

      # After range
      insert(:calendar_event_cache,
        calendar_integration: integration,
        start_at: ~U[2026-07-15 10:00:00Z],
        end_at: ~U[2026-07-15 11:00:00Z]
      )

      result = CalendarEventCacheQueries.list_for_range([integration.id], range_start, range_end)

      assert [event] = result
      assert event.id == overlapping.id
    end

    test "returns events ordered by start_at" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      later =
        insert(:calendar_event_cache,
          calendar_integration: integration,
          start_at: ~U[2026-06-20 10:00:00Z],
          end_at: ~U[2026-06-20 11:00:00Z]
        )

      earlier =
        insert(:calendar_event_cache,
          calendar_integration: integration,
          start_at: ~U[2026-06-10 10:00:00Z],
          end_at: ~U[2026-06-10 11:00:00Z]
        )

      result =
        CalendarEventCacheQueries.list_for_range(
          [integration.id],
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z]
        )

      assert [first, second] = result
      assert first.id == earlier.id
      assert second.id == later.id
    end

    test "returns events across multiple integrations" do
      user = insert(:user)
      int1 = insert(:calendar_integration, user: user)
      int2 = insert(:calendar_integration, user: user)

      e1 =
        insert(:calendar_event_cache,
          calendar_integration: int1,
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z]
        )

      e2 =
        insert(:calendar_event_cache,
          calendar_integration: int2,
          start_at: ~U[2026-06-16 10:00:00Z],
          end_at: ~U[2026-06-16 11:00:00Z]
        )

      result =
        CalendarEventCacheQueries.list_for_range(
          [int1.id, int2.id],
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z]
        )

      assert length(result) == 2
      ids = Enum.map(result, & &1.id)
      assert e1.id in ids
      assert e2.id in ids
    end
  end

  describe "upsert_batch/1" do
    test "returns {:ok, 0} for empty list" do
      assert {:ok, 0} = CalendarEventCacheQueries.upsert_batch([])
    end

    test "inserts new events" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      attrs1 = build_event_attrs(integration, %{uid: "batch-1", title: "Event 1"})
      attrs2 = build_event_attrs(integration, %{uid: "batch-2", title: "Event 2"})

      assert {:ok, 2} = CalendarEventCacheQueries.upsert_batch([attrs1, attrs2])

      events =
        Repo.all(
          from(e in CalendarEventCacheSchema,
            where: e.calendar_integration_id == ^integration.id,
            order_by: e.uid
          )
        )

      assert [%{uid: "batch-1", title: "Event 1"}, %{uid: "batch-2", title: "Event 2"}] = events
    end

    test "updates existing events on uid conflict" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      attrs = build_event_attrs(integration, %{uid: "update-me", title: "Original"})
      {:ok, 1} = CalendarEventCacheQueries.upsert_batch([attrs])

      updated_attrs = %{attrs | title: "Updated"}
      {:ok, 1} = CalendarEventCacheQueries.upsert_batch([updated_attrs])

      [event] =
        Repo.all(
          from(e in CalendarEventCacheSchema,
            where:
              e.calendar_integration_id == ^integration.id and
                e.uid == "update-me"
          )
        )

      assert event.title == "Updated"
    end
  end

  describe "delete_by_uid/2" do
    test "deletes existing event" do
      event = insert(:calendar_event_cache)

      assert {:ok, :deleted} =
               CalendarEventCacheQueries.delete_by_uid(
                 event.calendar_integration_id,
                 event.uid
               )

      refute Repo.get(CalendarEventCacheSchema, event.id)
    end

    test "returns :not_found for non-existent uid" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:ok, :not_found} =
               CalendarEventCacheQueries.delete_by_uid(integration.id, "nonexistent")
    end
  end

  describe "delete_by_provider_event_id/2" do
    test "deletes existing event by provider_event_id" do
      event =
        insert(:calendar_event_cache, provider_event_id: "provider-123")

      assert {:ok, :deleted} =
               CalendarEventCacheQueries.delete_by_provider_event_id(
                 event.calendar_integration_id,
                 "provider-123"
               )

      refute Repo.get(CalendarEventCacheSchema, event.id)
    end

    test "returns :not_found when no match" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:ok, :not_found} =
               CalendarEventCacheQueries.delete_by_provider_event_id(
                 integration.id,
                 "nonexistent"
               )
    end
  end

  describe "full_refresh_for_integration/2" do
    test "replaces all events for an integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:calendar_event_cache, calendar_integration: integration, uid: "old-1")
      insert(:calendar_event_cache, calendar_integration: integration, uid: "old-2")

      new_attrs = build_event_attrs(integration, %{uid: "new-1", title: "Fresh"})

      assert {:ok, 1} =
               CalendarEventCacheQueries.full_refresh_for_integration(
                 integration.id,
                 [new_attrs]
               )

      events =
        Repo.all(
          from(e in CalendarEventCacheSchema,
            where: e.calendar_integration_id == ^integration.id
          )
        )

      assert [%{uid: "new-1", title: "Fresh"}] = events
    end

    test "does not affect other integrations" do
      user = insert(:user)
      int1 = insert(:calendar_integration, user: user)
      int2 = insert(:calendar_integration, user: user)

      kept = insert(:calendar_event_cache, calendar_integration: int2, uid: "keep-me")
      insert(:calendar_event_cache, calendar_integration: int1, uid: "replace-me")

      new_attrs = build_event_attrs(int1, %{uid: "replacement"})
      {:ok, 1} = CalendarEventCacheQueries.full_refresh_for_integration(int1.id, [new_attrs])

      # int2's event is untouched
      assert Repo.get(CalendarEventCacheSchema, kept.id)
    end
  end

  describe "prune_ended_before/1" do
    test "deletes events that ended before cutoff" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      insert(:calendar_event_cache,
        calendar_integration: integration,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z]
      )

      future =
        insert(:calendar_event_cache,
          calendar_integration: integration,
          start_at: ~U[2026-07-01 10:00:00Z],
          end_at: ~U[2026-07-01 11:00:00Z]
        )

      assert 1 = CalendarEventCacheQueries.prune_ended_before(cutoff)
      assert Repo.get(CalendarEventCacheSchema, future.id)
    end
  end

  describe "prune_inactive_integrations/0" do
    test "deletes events for inactive integrations" do
      user = insert(:user)
      active = insert(:calendar_integration, user: user, is_active: true)
      inactive = insert(:calendar_integration, user: user, is_active: false)

      kept = insert(:calendar_event_cache, calendar_integration: active)
      insert(:calendar_event_cache, calendar_integration: inactive)

      assert 1 = CalendarEventCacheQueries.prune_inactive_integrations()
      assert Repo.get(CalendarEventCacheSchema, kept.id)
    end
  end
end
