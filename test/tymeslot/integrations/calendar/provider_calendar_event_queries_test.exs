defmodule Tymeslot.Integrations.Calendar.CalendarEventCacheQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  defp build_event_attrs(integration, overrides) do
    now = DateTime.utc_now(:microsecond)

    Map.merge(
      %{
        uid: "event-#{System.unique_integer([:positive])}",
        calendar_integration_id: integration.id,
        provider: "google",
        provider_calendar_id: "primary",
        start_at: now,
        end_at: DateTime.add(now, 3600, :second),
        all_day: false,
        transparency: "opaque",
        status: "confirmed",
        summary: "Test Event",
        synced_at: now,
        provider_metadata: %{}
      },
      overrides
    )
  end

  describe "list_for_range/3" do
    test "returns empty list for empty integration_ids" do
      assert [] =
               ProviderCalendarEventQueries.list_for_range(
                 [],
                 ~U[2026-01-01 00:00:00Z],
                 ~U[2026-12-31 23:59:59Z]
               )
    end

    test "returns timed events overlapping the range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      range_start = ~U[2026-06-01 00:00:00Z]
      range_end = ~U[2026-06-30 23:59:59Z]

      # Before range
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z]
      )

      # Overlapping range
      overlapping =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z]
        )

      # After range
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-07-15 10:00:00Z],
        end_at: ~U[2026-07-15 11:00:00Z]
      )

      result =
        ProviderCalendarEventQueries.list_for_range([integration.id], range_start, range_end)

      assert [event] = result
      assert event.id == overlapping.id
    end

    test "returns all-day events overlapping the range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      range_start = ~U[2026-06-01 00:00:00Z]
      range_end = ~U[2026-06-30 23:59:59Z]

      # All-day event within range
      all_day =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          all_day: true,
          start_date: ~D[2026-06-10],
          end_date: ~D[2026-06-11],
          start_at: nil,
          end_at: nil
        )

      # All-day event outside range
      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-08-01],
        end_date: ~D[2026-08-02],
        start_at: nil,
        end_at: nil
      )

      result =
        ProviderCalendarEventQueries.list_for_range([integration.id], range_start, range_end)

      assert [event] = result
      assert event.id == all_day.id
    end

    test "returns events ordered by start time" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      later =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: ~U[2026-06-20 10:00:00Z],
          end_at: ~U[2026-06-20 11:00:00Z]
        )

      earlier =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: ~U[2026-06-10 10:00:00Z],
          end_at: ~U[2026-06-10 11:00:00Z]
        )

      result =
        ProviderCalendarEventQueries.list_for_range(
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
        insert(:provider_calendar_event,
          calendar_integration: int1,
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z]
        )

      e2 =
        insert(:provider_calendar_event,
          calendar_integration: int2,
          start_at: ~U[2026-06-16 10:00:00Z],
          end_at: ~U[2026-06-16 11:00:00Z]
        )

      result =
        ProviderCalendarEventQueries.list_for_range(
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

  describe "list_uids_in_range/4" do
    test "returns uid of timed event overlapping the range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z],
          synced_at: ~U[2026-05-31 23:59:59Z]
        )

      result =
        ProviderCalendarEventQueries.list_uids_in_range(
          integration.id,
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z],
          cutoff
        )

      assert result == [event.uid]
    end

    test "does not return timed event outside the range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-07-01 10:00:00Z],
        end_at: ~U[2026-07-01 11:00:00Z],
        synced_at: ~U[2026-05-31 23:59:59Z]
      )

      result =
        ProviderCalendarEventQueries.list_uids_in_range(
          integration.id,
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z],
          cutoff
        )

      assert result == []
    end

    test "returns uid of all-day event overlapping the range by date" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          all_day: true,
          start_date: ~D[2026-06-10],
          end_date: ~D[2026-06-11],
          start_at: nil,
          end_at: nil,
          synced_at: ~U[2026-05-31 23:59:59Z]
        )

      result =
        ProviderCalendarEventQueries.list_uids_in_range(
          integration.id,
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z],
          cutoff
        )

      assert result == [event.uid]
    end

    test "does not return all-day event outside the range" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-08-01],
        end_date: ~D[2026-08-02],
        start_at: nil,
        end_at: nil,
        synced_at: ~U[2026-05-31 23:59:59Z]
      )

      result =
        ProviderCalendarEventQueries.list_uids_in_range(
          integration.id,
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z],
          cutoff
        )

      assert result == []
    end

    test "does not return event synced at or after cutoff" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      # synced_at == cutoff — must not appear
      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z],
        synced_at: cutoff
      )

      result =
        ProviderCalendarEventQueries.list_uids_in_range(
          integration.id,
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z],
          cutoff
        )

      assert result == []
    end

    test "filters by calendar_path prefix — returns only matching paths" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      matching =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider_event_id: "/calendars/work/event-1.ics",
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z],
          synced_at: ~U[2026-05-31 23:59:59Z]
        )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_event_id: "/calendars/personal/event-2.ics",
        start_at: ~U[2026-06-16 10:00:00Z],
        end_at: ~U[2026-06-16 11:00:00Z],
        synced_at: ~U[2026-05-31 23:59:59Z]
      )

      result =
        ProviderCalendarEventQueries.list_uids_in_range(
          integration.id,
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z],
          cutoff,
          "/calendars/work/"
        )

      assert result == [matching.uid]
    end

    test "calendar_path with underscores is treated literally, not as a wildcard" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      # Path with underscore in prefix
      matching =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider_event_id: "/calendars/my_calendar/event-1.ics",
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z],
          synced_at: ~U[2026-05-31 23:59:59Z]
        )

      # Path where the underscore position is a different character — should NOT match
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_event_id: "/calendars/myXcalendar/event-2.ics",
        start_at: ~U[2026-06-16 10:00:00Z],
        end_at: ~U[2026-06-16 11:00:00Z],
        synced_at: ~U[2026-05-31 23:59:59Z]
      )

      result =
        ProviderCalendarEventQueries.list_uids_in_range(
          integration.id,
          ~U[2026-06-01 00:00:00Z],
          ~U[2026-06-30 23:59:59Z],
          cutoff,
          "/calendars/my_calendar/"
        )

      assert result == [matching.uid]
    end
  end

  describe "upsert_batch/1" do
    test "returns {:ok, 0} for empty list" do
      assert {:ok, 0} = ProviderCalendarEventQueries.upsert_batch([])
    end

    test "inserts new events" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      attrs1 = build_event_attrs(integration, %{uid: "batch-1", summary: "Event 1"})
      attrs2 = build_event_attrs(integration, %{uid: "batch-2", summary: "Event 2"})

      assert {:ok, 2} = ProviderCalendarEventQueries.upsert_batch([attrs1, attrs2])

      events =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id,
            order_by: e.uid
          )
        )

      assert [%{uid: "batch-1", summary: "Event 1"}, %{uid: "batch-2", summary: "Event 2"}] =
               events
    end

    test "updates existing events on uid conflict" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      attrs = build_event_attrs(integration, %{uid: "update-me", summary: "Original"})
      {:ok, 1} = ProviderCalendarEventQueries.upsert_batch([attrs])

      updated_attrs = %{attrs | summary: "Updated"}
      {:ok, 1} = ProviderCalendarEventQueries.upsert_batch([updated_attrs])

      [event] =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where:
              e.calendar_integration_id == ^integration.id and
                e.uid == "update-me"
          )
        )

      assert event.summary == "Updated"
    end
  end

  describe "get_by_uid/2" do
    test "returns {:ok, event} when the uid exists for the integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "get-by-uid-test"
        )

      assert {:ok, found} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert found.id == event.id
      assert found.uid == "get-by-uid-test"
    end

    test "returns {:error, :not_found} for a non-existent uid" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "does-not-exist")
    end

    test "does not return an event belonging to a different integration" do
      user = insert(:user)
      int1 = insert(:calendar_integration, user: user)
      int2 = insert(:calendar_integration, user: user)

      event = insert(:provider_calendar_event, calendar_integration: int1)

      assert {:error, :not_found} = ProviderCalendarEventQueries.get_by_uid(int2.id, event.uid)
    end
  end

  describe "delete_by_uid/2" do
    test "deletes existing event" do
      event = insert(:provider_calendar_event)

      assert {:ok, :deleted} =
               ProviderCalendarEventQueries.delete_by_uid(
                 event.calendar_integration_id,
                 event.uid
               )

      refute Repo.get(ProviderCalendarEventSchema, event.id)
    end

    test "returns :not_found for non-existent uid" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:ok, :not_found} =
               ProviderCalendarEventQueries.delete_by_uid(integration.id, "nonexistent")
    end
  end

  describe "delete_by_provider_event_id/2" do
    test "deletes existing event by provider_event_id" do
      event =
        insert(:provider_calendar_event, provider_event_id: "provider-123")

      assert {:ok, :deleted} =
               ProviderCalendarEventQueries.delete_by_provider_event_id(
                 event.calendar_integration_id,
                 "provider-123"
               )

      refute Repo.get(ProviderCalendarEventSchema, event.id)
    end

    test "returns :not_found when no match" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:ok, :not_found} =
               ProviderCalendarEventQueries.delete_by_provider_event_id(
                 integration.id,
                 "nonexistent"
               )
    end
  end

  describe "full_refresh_for_integration/2" do
    test "replaces all events for an integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event, calendar_integration: integration, uid: "old-1")
      insert(:provider_calendar_event, calendar_integration: integration, uid: "old-2")

      new_attrs = build_event_attrs(integration, %{uid: "new-1", summary: "Fresh"})

      assert {:ok, 1} =
               ProviderCalendarEventQueries.full_refresh_for_integration(
                 integration.id,
                 [new_attrs]
               )

      events =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id
          )
        )

      assert [%{uid: "new-1", summary: "Fresh"}] = events
    end

    test "does not affect other integrations" do
      user = insert(:user)
      int1 = insert(:calendar_integration, user: user)
      int2 = insert(:calendar_integration, user: user)

      kept = insert(:provider_calendar_event, calendar_integration: int2, uid: "keep-me")
      insert(:provider_calendar_event, calendar_integration: int1, uid: "replace-me")

      new_attrs = build_event_attrs(int1, %{uid: "replacement"})
      {:ok, 1} = ProviderCalendarEventQueries.full_refresh_for_integration(int1.id, [new_attrs])

      # int2's event is untouched
      assert Repo.get(ProviderCalendarEventSchema, kept.id)
    end
  end

  describe "prune_ended_before/1" do
    test "deletes timed events that ended before cutoff" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      insert(:provider_calendar_event,
        calendar_integration: integration,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z]
      )

      future =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          start_at: ~U[2026-07-01 10:00:00Z],
          end_at: ~U[2026-07-01 11:00:00Z]
        )

      assert 1 = ProviderCalendarEventQueries.prune_ended_before(cutoff)
      assert Repo.get(ProviderCalendarEventSchema, future.id)
    end

    test "deletes all-day events that ended before cutoff" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      cutoff = ~U[2026-06-01 00:00:00Z]

      insert(:provider_calendar_event,
        calendar_integration: integration,
        all_day: true,
        start_date: ~D[2026-04-01],
        end_date: ~D[2026-04-02],
        start_at: nil,
        end_at: nil
      )

      future =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          all_day: true,
          start_date: ~D[2026-07-01],
          end_date: ~D[2026-07-02],
          start_at: nil,
          end_at: nil
        )

      assert 1 = ProviderCalendarEventQueries.prune_ended_before(cutoff)
      assert Repo.get(ProviderCalendarEventSchema, future.id)
    end
  end

  describe "from_calendar_event/1 round-trip via upsert" do
    test "stored and reloaded event equals original CalendarEvent on key fields" do
      alias Tymeslot.Integrations.Calendar.CalendarEvent
      alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      now = DateTime.utc_now(:microsecond)

      original =
        CalendarEvent.new!(%{
          uid: "roundtrip-uid-1",
          calendar_integration_id: integration.id,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "provider-rt-1",
          all_day: false,
          start_at: now,
          end_at: DateTime.add(now, 3600, :second),
          transparency: :transparent,
          status: :tentative,
          visibility: :private,
          synced_at: now
        })

      attrs = ProviderCalendarEventSchema.from_calendar_event(original)
      assert {:ok, 1} = ProviderCalendarEventQueries.upsert_batch([attrs])

      {:ok, loaded} = ProviderCalendarEventQueries.get_by_uid(integration.id, original.uid)
      rehydrated = ProviderCalendarEventSchema.to_calendar_event(loaded)

      assert rehydrated.uid == original.uid
      assert rehydrated.provider == original.provider
      assert rehydrated.transparency == original.transparency
      assert rehydrated.status == original.status
      assert rehydrated.visibility == original.visibility
      assert rehydrated.provider_event_id == original.provider_event_id
    end
  end

  describe "prune_inactive_integrations/0" do
    test "deletes events for inactive integrations" do
      user = insert(:user)
      active = insert(:calendar_integration, user: user, is_active: true)
      inactive = insert(:calendar_integration, user: user, is_active: false)

      kept = insert(:provider_calendar_event, calendar_integration: active)
      insert(:provider_calendar_event, calendar_integration: inactive)

      assert 1 = ProviderCalendarEventQueries.prune_inactive_integrations()
      assert Repo.get(ProviderCalendarEventSchema, kept.id)
    end
  end
end
