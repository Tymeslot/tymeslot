defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventSearchQueriesTest do
  @moduledoc """
  Free-text search over the cached calendar events: the old calendar's
  `search/3` (moved here unchanged) and the calendar's `search_around/3`,
  nearest to a moment first.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSearchQueries

  @from ~U[2026-10-14 08:00:00Z]

  describe "search/3" do
    setup do
      user = insert(:user)
      visible = insert(:calendar_integration, user: user, is_active: true)
      hidden = insert(:calendar_integration, user: user, is_active: true)
      %{user: user, visible: visible, hidden: hidden}
    end

    test "returns [] for a blank or whitespace-only term", %{user: user} do
      assert ProviderCalendarEventSearchQueries.search(user.id, "") == []
      assert ProviderCalendarEventSearchQueries.search(user.id, "   ") == []
    end

    test "matches the summary case-insensitively", %{user: user, visible: visible} do
      event =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Quarterly Strategy Review"
        )

      assert [%{id: id}] = ProviderCalendarEventSearchQueries.search(user.id, "strategy")
      assert id == event.id
    end

    test "matches the description", %{user: user, visible: visible} do
      event =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Sync",
          description: "Discuss the migration plan"
        )

      assert [%{id: id}] = ProviderCalendarEventSearchQueries.search(user.id, "migration")
      assert id == event.id
    end

    test "matches the location", %{user: user, visible: visible} do
      event =
        insert(:provider_calendar_event,
          calendar_integration: visible,
          summary: "Standup",
          location: "Conference Room Berlin"
        )

      assert [%{id: id}] = ProviderCalendarEventSearchQueries.search(user.id, "berlin")
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
        ProviderCalendarEventSearchQueries.search(user.id, "planning",
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

      assert ProviderCalendarEventSearchQueries.search(user.id, "roadmap") == []
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

      assert [first, second] = ProviderCalendarEventSearchQueries.search(user.id, "demo")
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

      assert length(ProviderCalendarEventSearchQueries.search(user.id, "repeat", limit: 2)) == 2
    end
  end

  defp timed(integration, summary, start_at, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          summary: summary,
          start_at: start_at,
          end_at: DateTime.add(start_at, 60, :minute),
          all_day: false
        ],
        attrs
      )
    )
  end

  defp summaries(rows), do: Enum.map(rows, & &1.summary)

  describe "search_around/3" do
    setup do
      user = insert(:user)
      %{user: user, integration: insert(:calendar_integration, user: user, is_active: true)}
    end

    test "upcoming rows run ascending from the moment, past rows latest first", %{
      user: user,
      integration: integration
    } do
      timed(integration, "Plan minus two", DateTime.add(@from, -2, :day))
      timed(integration, "Plan minus one", DateTime.add(@from, -1, :day))
      timed(integration, "Plan plus one", DateTime.add(@from, 1, :day))
      timed(integration, "Plan plus two", DateTime.add(@from, 2, :day))

      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Plan all day",
        all_day: true,
        start_at: nil,
        end_at: nil,
        start_date: ~D[2026-10-20],
        end_date: ~D[2026-10-21]
      )

      result = ProviderCalendarEventSearchQueries.search_around(user.id, "plan", from: @from)

      assert summaries(result.upcoming) == ["Plan plus one", "Plan plus two", "Plan all day"]
      assert summaries(result.past) == ["Plan minus one", "Plan minus two"]
    end

    test "each side is capped by :limit", %{user: user, integration: integration} do
      for days <- [-3, -2, -1, 1, 2, 3],
          do: timed(integration, "Sync #{days}", DateTime.add(@from, days, :day))

      result =
        ProviderCalendarEventSearchQueries.search_around(user.id, "sync", from: @from, limit: 2)

      assert summaries(result.upcoming) == ["Sync 1", "Sync 2"]
      assert summaries(result.past) == ["Sync -1", "Sync -2"]
    end

    test "a blank term finds nothing", %{user: user, integration: integration} do
      timed(integration, "Anything", DateTime.add(@from, 1, :day))

      assert ProviderCalendarEventSearchQueries.search_around(user.id, "   ", from: @from) ==
               %{upcoming: [], past: []}
    end

    test "busy time with nothing to show and rows deleted locally are left out", %{
      user: user,
      integration: integration
    } do
      timed(integration, "Review kept", DateTime.add(@from, 1, :day))
      timed(integration, "Review busy", DateTime.add(@from, 2, :day), role: EventRole.busy_only())

      timed(integration, "Review deleted", DateTime.add(@from, 3, :day),
        sync_state: "locally_deleted"
      )

      result = ProviderCalendarEventSearchQueries.search_around(user.id, "review", from: @from)

      assert summaries(result.upcoming) == ["Review kept"]
    end

    test "hidden integrations are left out", %{user: user, integration: integration} do
      other = insert(:calendar_integration, user: user, is_active: true)
      timed(integration, "Offsite kept", DateTime.add(@from, 1, :day))
      timed(other, "Offsite hidden", DateTime.add(@from, 1, :day))

      result =
        ProviderCalendarEventSearchQueries.search_around(user.id, "offsite",
          from: @from,
          hidden_integration_ids: [other.id]
        )

      assert summaries(result.upcoming) == ["Offsite kept"]
    end
  end
end
