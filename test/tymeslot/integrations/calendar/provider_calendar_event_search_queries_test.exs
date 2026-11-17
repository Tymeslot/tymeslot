defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventSearchQueriesTest do
  @moduledoc """
  Free-text search over the cached calendar events: the calendar's
  `search_around/3`, nearest to a moment first.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSearchQueries

  @from ~U[2026-10-14 08:00:00Z]

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

    test "matches the summary, description and location case-insensitively", %{
      user: user,
      integration: integration
    } do
      timed(integration, "Quarterly Strategy Review", DateTime.add(@from, 1, :day))

      timed(integration, "Sync", DateTime.add(@from, 2, :day),
        description: "Discuss the migration plan"
      )

      timed(integration, "Standup", DateTime.add(@from, 3, :day),
        location: "Conference Room Berlin"
      )

      for {term, summary} <- [
            {"strategy", "Quarterly Strategy Review"},
            {"MIGRATION", "Sync"},
            {"berlin", "Standup"}
          ] do
        result = ProviderCalendarEventSearchQueries.search_around(user.id, term, from: @from)
        assert summaries(result.upcoming) == [summary]
      end
    end

    test "another user's events are left out", %{user: user} do
      other = insert(:calendar_integration, user: insert(:user), is_active: true)
      timed(other, "Confidential roadmap", DateTime.add(@from, 1, :day))

      assert ProviderCalendarEventSearchQueries.search_around(user.id, "roadmap", from: @from) ==
               %{upcoming: [], past: []}
    end

    # More than four times the limit of earlier matches in a deselected
    # calendar: filtered after the query, they would fill the page.
    test "a deselected calendar's rows do not crowd a selected match out", %{
      user: user,
      integration: integration
    } do
      deselected =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          provider: "caldav",
          calendar_paths: [],
          calendar_list: [%{"id" => "/cal/team/", "path" => "/cal/team/", "selected" => false}]
        )

      for n <- 1..13 do
        timed(deselected, "Standup #{n}", DateTime.add(@from, n, :hour),
          provider_event_id: "/cal/team/evt-#{n}.ics"
        )
      end

      timed(integration, "Standup kickoff", DateTime.add(@from, 1, :day))

      result =
        ProviderCalendarEventSearchQueries.search_around(user.id, "standup",
          from: @from,
          limit: 3,
          visibility_rules: Calendar.visibility_rules([integration, deselected])
        )

      assert summaries(result.upcoming) == ["Standup kickoff"]
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
