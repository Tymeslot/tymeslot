defmodule Tymeslot.Integrations.Calendar.CalendarEventCacheQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

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
end
