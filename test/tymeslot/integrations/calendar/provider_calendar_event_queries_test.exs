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

  describe "search/3" do
    setup do
      user = insert(:user)
      visible = insert(:calendar_integration, user: user, is_active: true)
      hidden = insert(:calendar_integration, user: user, is_active: true)
      %{user: user, visible: visible, hidden: hidden}
    end

    test "returns [] for a blank or whitespace-only term", %{user: user} do
      assert ProviderCalendarEventQueries.search(user.id, "") == []
      assert ProviderCalendarEventQueries.search(user.id, "   ") == []
    end

    test "matches the summary case-insensitively", %{user: user, visible: visible} do
      event =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Quarterly Strategy Review"
        )

      assert [%{id: id}] = ProviderCalendarEventQueries.search(user.id, "strategy")
      assert id == event.id
    end

    test "matches the description", %{user: user, visible: visible} do
      event =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Sync",
          description: "Discuss the migration plan"
        )

      assert [%{id: id}] = ProviderCalendarEventQueries.search(user.id, "migration")
      assert id == event.id
    end

    test "matches the location", %{user: user, visible: visible} do
      event =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Standup",
          location: "Conference Room Berlin"
        )

      assert [%{id: id}] = ProviderCalendarEventQueries.search(user.id, "berlin")
      assert id == event.id
    end

    test "excludes integrations passed in hidden_integration_ids", %{
      user: user,
      visible: visible,
      hidden: hidden
    } do
      kept =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Planning workshop"
        )

      insert(:provider_calendar_event,
        calendar_integration: hidden,
        summary: "Hidden planning session"
      )

      result =
        ProviderCalendarEventQueries.search(user.id, "planning",
          hidden_integration_ids: [hidden.id]
        )

      assert [%{id: id}] = result
      assert id == kept.id
    end

    test "excludes events belonging to another user", %{user: user} do
      other_user = insert(:user)
      other_integration = insert(:calendar_integration, user: other_user, is_active: true)

      insert(:provider_calendar_event,
        calendar_integration: other_integration,
        summary: "Confidential roadmap"
      )

      assert ProviderCalendarEventQueries.search(user.id, "roadmap") == []
    end

    test "orders matches by start time ascending", %{user: user, visible: visible} do
      later =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Demo finale",
          start_at: ~U[2026-06-20 10:00:00Z],
          end_at: ~U[2026-06-20 11:00:00Z]
        )

      earlier =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Demo kickoff",
          start_at: ~U[2026-06-01 10:00:00Z],
          end_at: ~U[2026-06-01 11:00:00Z]
        )

      assert [first, second] = ProviderCalendarEventQueries.search(user.id, "demo")
      assert first.id == earlier.id
      assert second.id == later.id
    end

    test "respects the limit option", %{user: user, visible: visible} do
      for n <- 1..3 do
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Repeat meeting #{n}"
        )
      end

      assert length(ProviderCalendarEventQueries.search(user.id, "repeat", limit: 2)) == 2
    end
  end

  describe "existing_uids/2" do
    setup do
      user = insert(:user)
      %{integration: insert(:calendar_integration, user: user)}
    end

    test "returns the subset of UIDs the cache holds", %{integration: integration} do
      insert(:provider_calendar_event, calendar_integration: integration, uid: "here-1")
      insert(:provider_calendar_event, calendar_integration: integration, uid: "here-2")

      assert ProviderCalendarEventQueries.existing_uids(integration.id, [
               "here-1",
               "here-2",
               "gone"
             ]) == MapSet.new(["here-1", "here-2"])
    end

    # The point of the function. The reconcile sweep uses it to distinguish a
    # source that was deleted from one that merely sits outside the window it
    # re-diffs, so a date filter here would defeat it entirely and take every
    # far-future mirror down with it.
    test "ignores how far outside any sync window the event sits", %{integration: integration} do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "decade-out",
        start_at: ~U[2040-01-01 09:00:00Z],
        end_at: ~U[2040-01-01 10:00:00Z]
      )

      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "decade-past",
        start_at: ~U[2010-01-01 09:00:00Z],
        end_at: ~U[2010-01-01 10:00:00Z]
      )

      assert ProviderCalendarEventQueries.existing_uids(integration.id, [
               "decade-out",
               "decade-past"
             ]) == MapSet.new(["decade-out", "decade-past"])
    end

    test "is scoped to the integration asked for", %{integration: integration} do
      other = insert(:calendar_integration)
      insert(:provider_calendar_event, calendar_integration: other, uid: "elsewhere")

      assert ProviderCalendarEventQueries.existing_uids(integration.id, ["elsewhere"]) ==
               MapSet.new()
    end

    test "returns an empty set for no UIDs", %{integration: integration} do
      assert ProviderCalendarEventQueries.existing_uids(integration.id, []) == MapSet.new()
    end
  end
end
