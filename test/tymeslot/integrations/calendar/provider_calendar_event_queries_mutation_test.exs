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

  # `provider_calendar_id` records which of an integration's calendars a row was
  # synced from, and it is read to route provider calls — `RecurringSeries`
  # fetches a series master from the calendar its instances live on, because
  # asking the integration's booking calendar instead draws a 404 for an event
  # that is plainly there.
  #
  # It was pinned at insert and never updated, so an event moved between two
  # calendars of one integration kept naming the calendar it left. The master
  # fetch then 404s for as long as the series exists, and the skip is a discard
  # rather than an error, so no job fails and nothing is logged above info: a
  # recurring mirror silently stops updating.
  #
  # The column was held back from `replace_fields/0` against partial cache-update
  # maps writing EXCLUDED — NULL — over a good value. That cannot happen: the
  # column is NOT NULL, so such a row fails at insert rather than reaching the
  # conflict clause, and the one partial caller
  # (`CalendarGrid.update_cached_event/1`) builds its row through
  # `build_cache_row/2`, which always carries the existing `provider_calendar_id`
  # forward. The guard cost a real behaviour and prevented nothing.
  describe "upsert_batch/1 and the calendar a row was synced from" do
    test "follows an event moved to another calendar of the same integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      attrs = build_event_attrs(integration, %{uid: "moved-1", provider_calendar_id: "primary"})
      assert {:ok, 1} = ProviderCalendarEventQueries.upsert_batch([attrs])

      moved = Map.put(attrs, :provider_calendar_id, "work@example.com")
      assert {:ok, 1} = ProviderCalendarEventQueries.upsert_batch([moved])

      assert {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "moved-1")
      assert row.provider_calendar_id == "work@example.com"
    end

    test "a row omitting the calendar is refused rather than stored without one" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      attrs = build_event_attrs(integration, %{uid: "partial-1"})
      partial = Map.delete(attrs, :provider_calendar_id)

      # The NOT NULL constraint, asserted so the reasoning above stays true: if
      # the column ever became nullable, replacing it would need the conditional
      # update the comment on `replace_fields/0` was written to avoid.
      assert_raise Postgrex.Error, fn ->
        ProviderCalendarEventQueries.upsert_batch([partial])
      end
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

  describe "delete_by_uids/2" do
    test "returns {0, _} and deletes nothing for an empty list" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      insert(:provider_calendar_event, calendar_integration: integration, uid: "kept")

      assert 0 = ProviderCalendarEventQueries.delete_by_uids(integration.id, [])

      assert Repo.aggregate(
               from(e in ProviderCalendarEventSchema,
                 where: e.calendar_integration_id == ^integration.id
               ),
               :count
             ) == 1
    end

    test "deletes exactly the matching rows and returns the correct count" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event, calendar_integration: integration, uid: "delete-1")
      insert(:provider_calendar_event, calendar_integration: integration, uid: "delete-2")
      insert(:provider_calendar_event, calendar_integration: integration, uid: "keep")

      assert 2 =
               ProviderCalendarEventQueries.delete_by_uids(integration.id, [
                 "delete-1",
                 "delete-2"
               ])

      remaining =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id
          )
        )

      assert [%{uid: "keep"}] = remaining
    end

    test "does not delete events belonging to a different integration" do
      user = insert(:user)
      int1 = insert(:calendar_integration, user: user)
      int2 = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event, calendar_integration: int1, uid: "shared-uid")
      other = insert(:provider_calendar_event, calendar_integration: int2, uid: "shared-uid")

      assert 1 = ProviderCalendarEventQueries.delete_by_uids(int1.id, ["shared-uid"])

      assert Repo.get(ProviderCalendarEventSchema, other.id)
    end

    test "deletes all matching rows across chunks for a list larger than the chunk size" do
      # Regression: delete_by_uids must chunk the `in` list the same way
      # upsert_batch does, or it can exceed Postgres' 65,535 bind-parameter
      # limit. 1,200 uids exercises more than one chunk at the 1,000-row
      # chunk size.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      uids =
        Enum.map(1..1200, fn n ->
          event =
            insert(:provider_calendar_event, calendar_integration: integration, uid: "bulk-#{n}")

          event.uid
        end)

      assert 1200 = ProviderCalendarEventQueries.delete_by_uids(integration.id, uids)

      assert Repo.aggregate(
               from(e in ProviderCalendarEventSchema,
                 where: e.calendar_integration_id == ^integration.id
               ),
               :count
             ) == 0
    end
  end

  describe "delete_by_provider_event_ids/2" do
    test "returns {0, _} and deletes nothing for an empty list" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_event_id: "kept"
      )

      assert 0 = ProviderCalendarEventQueries.delete_by_provider_event_ids(integration.id, [])

      assert Repo.aggregate(
               from(e in ProviderCalendarEventSchema,
                 where: e.calendar_integration_id == ^integration.id
               ),
               :count
             ) == 1
    end

    test "deletes exactly the matching rows and returns the correct count" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_event_id: "provider-delete-1"
      )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_event_id: "provider-delete-2"
      )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider_event_id: "provider-keep"
      )

      assert 2 =
               ProviderCalendarEventQueries.delete_by_provider_event_ids(integration.id, [
                 "provider-delete-1",
                 "provider-delete-2"
               ])

      remaining =
        Repo.all(
          from(e in ProviderCalendarEventSchema,
            where: e.calendar_integration_id == ^integration.id
          )
        )

      assert [%{provider_event_id: "provider-keep"}] = remaining
    end

    test "does not delete events belonging to a different integration" do
      user = insert(:user)
      int1 = insert(:calendar_integration, user: user)
      int2 = insert(:calendar_integration, user: user)

      insert(:provider_calendar_event,
        calendar_integration: int1,
        provider_event_id: "shared-provider-id"
      )

      other =
        insert(:provider_calendar_event,
          calendar_integration: int2,
          provider_event_id: "shared-provider-id"
        )

      assert 1 =
               ProviderCalendarEventQueries.delete_by_provider_event_ids(int1.id, [
                 "shared-provider-id"
               ])

      assert Repo.get(ProviderCalendarEventSchema, other.id)
    end

    test "deletes all matching rows across chunks for a list larger than the chunk size" do
      # Regression: delete_by_provider_event_ids must chunk the `in` list the
      # same way upsert_batch does, or it can exceed Postgres' 65,535
      # bind-parameter limit. 1,200 ids exercises more than one chunk at the
      # 1,000-row chunk size.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      provider_event_ids =
        Enum.map(1..1200, fn n ->
          event =
            insert(:provider_calendar_event,
              calendar_integration: integration,
              provider_event_id: "provider-bulk-#{n}"
            )

          event.provider_event_id
        end)

      assert 1200 =
               ProviderCalendarEventQueries.delete_by_provider_event_ids(
                 integration.id,
                 provider_event_ids
               )

      assert Repo.aggregate(
               from(e in ProviderCalendarEventSchema,
                 where: e.calendar_integration_id == ^integration.id
               ),
               :count
             ) == 0
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
