defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventQueriesMutationTest do
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

    test "persists recurring events with recurrence_exceptions" do
      # Regression: recurrence_exceptions is typed {:array, :date}, so events
      # produced by the CalDAV event processor (which sources EXDATE from the
      # iCal parser) must round-trip through insert_all without a type clash.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      attrs =
        build_event_attrs(integration, %{
          uid: "recurring-with-exdate",
          recurrence_rule: "FREQ=WEEKLY;COUNT=3",
          recurrence_exceptions: [~D[2026-04-15], ~D[2026-04-22]]
        })

      assert {:ok, 1} = ProviderCalendarEventQueries.upsert_batch([attrs])

      [event] =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where:
              e.calendar_integration_id == ^integration.id and
                e.uid == "recurring-with-exdate"
          )
        )

      assert event.recurrence_exceptions == [~D[2026-04-15], ~D[2026-04-22]]
    end

    test "deduplicates entries with the same uid within a single batch" do
      # Regression: Google can return multiple instances of a recurring event
      # series (all sharing the same iCalUID) in one incremental sync response.
      # PostgreSQL rejects ON CONFLICT DO UPDATE when two rows in the same
      # command target the same constrained key; we must deduplicate first.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      attrs_first = build_event_attrs(integration, %{uid: "dup-uid", summary: "First"})
      attrs_last = build_event_attrs(integration, %{uid: "dup-uid", summary: "Last"})

      assert {:ok, _result} =
               ProviderCalendarEventQueries.upsert_batch([attrs_first, attrs_last])

      [event] =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id and e.uid == "dup-uid"
          )
        )

      assert event.summary == "Last"
    end

    test "inserts a batch larger than the Postgres bind-parameter limit" do
      # Regression: a single insert_all over ~30 columns exceeds PostgreSQL's
      # 65,535 bind-parameter limit around ~2,200 rows. A busy calendar's
      # initial Google sync (2,500 events per page) can plausibly exceed that,
      # so upsert_batch must chunk. 3,000 rows would fail as one statement.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      batch =
        Enum.map(1..3000, fn n ->
          build_event_attrs(integration, %{uid: "bulk-#{n}", summary: "Event #{n}"})
        end)

      assert {:ok, 3000} = ProviderCalendarEventQueries.upsert_batch(batch)

      assert 3000 ==
               Repo.aggregate(
                 from(e in ProviderCalendarEventSchema,
                   where: e.calendar_integration_id == ^integration.id
                 ),
                 :count
               )
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
end
