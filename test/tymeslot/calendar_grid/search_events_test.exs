defmodule Tymeslot.CalendarGrid.SearchEventsTest do
  @moduledoc """
  Covers `CalendarGrid.search_events/4`'s calendar-selection guard: a
  deselected calendar's cached rows must not be able to crowd a selected
  match out of the (limited) result set.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid

  test "a deselected calendar's rows do not crowd a selected match out of the results" do
    user = insert(:user)

    visible_integration = insert(:calendar_integration, user: user, is_active: true)

    deselected_integration =
      insert(:calendar_integration,
        user: user,
        is_active: true,
        provider: "caldav",
        calendar_paths: [],
        calendar_list: [%{"id" => "/cal/team/", "path" => "/cal/team/", "selected" => false}]
      )

    # More than the (batch-sized) limit of older, deselected-calendar matches,
    # all starting before the one selected-calendar match.
    for n <- 1..3 do
      insert(:provider_calendar_event,
        calendar_integration: deselected_integration,
        summary: "Standup #{n}",
        start_at: DateTime.add(~U[2026-06-01 09:00:00Z], n, :hour),
        provider_event_id: "/cal/team/evt-#{n}.ics"
      )
    end

    kept =
      insert(:provider_calendar_event,
        calendar_integration: visible_integration,
        summary: "Standup kickoff",
        start_at: ~U[2026-06-02 09:00:00Z]
      )

    result =
      CalendarGrid.search_events(
        user.id,
        "standup",
        [visible_integration, deselected_integration],
        limit: 3
      )

    assert [%{id: id}] = result
    assert id == kept.id
  end

  test "an unbounded run of deselected-calendar rows still can't crowd a selected match out" do
    user = insert(:user)

    visible_integration = insert(:calendar_integration, user: user, is_active: true)

    deselected_integration =
      insert(:calendar_integration,
        user: user,
        is_active: true,
        provider: "caldav",
        calendar_paths: [],
        calendar_list: [%{"id" => "/cal/team/", "path" => "/cal/team/", "selected" => false}]
      )

    # More than four times the limit of older, deselected-calendar matches:
    # a paged fetch capped at a fixed number of extra pages would give up
    # before ever reaching the selected match.
    for n <- 1..13 do
      insert(:provider_calendar_event,
        calendar_integration: deselected_integration,
        summary: "Standup #{n}",
        start_at: DateTime.add(~U[2026-06-01 09:00:00Z], n, :hour),
        provider_event_id: "/cal/team/evt-#{n}.ics"
      )
    end

    kept =
      insert(:provider_calendar_event,
        calendar_integration: visible_integration,
        summary: "Standup kickoff",
        start_at: ~U[2026-06-02 09:00:00Z]
      )

    result =
      CalendarGrid.search_events(
        user.id,
        "standup",
        [visible_integration, deselected_integration],
        limit: 3
      )

    assert [%{id: id}] = result
    assert id == kept.id
  end
end
