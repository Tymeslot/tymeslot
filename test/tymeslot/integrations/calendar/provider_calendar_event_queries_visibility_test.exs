defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventQueriesVisibilityTest do
  @moduledoc """
  Parity check between the SQL selection filter `list_upcoming_timed/4`
  applies via `:visibility_rules` and the in-memory `Selection.visible_events/2`
  the rest of the grid still uses. Both read `visible_events/2`'s own
  semantics (see its moduledoc); this test runs the same fixture set through
  both and asserts identical results, so the SQL filter cannot silently drift
  from the definition it is meant to mirror.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Selection

  @now ~U[2026-06-24 12:00:00.000000Z]
  @window_end DateTime.add(@now, 8, :day)

  test "SQL visibility_rules filtering agrees with Selection.visible_events/2" do
    # Legacy integration: no calendar_list at all, so every row is visible
    # regardless of tagging.
    legacy = insert(:calendar_integration, is_active: true, calendar_list: [])

    legacy_event =
      insert(:provider_calendar_event,
        calendar_integration: legacy,
        all_day: false,
        start_at: DateTime.add(@now, 1, :hour),
        provider_calendar_id: "anything",
        provider_event_id: "evt-legacy"
      )

    # Google-style integration: matched by provider_calendar_id equality.
    google =
      insert(:calendar_integration,
        is_active: true,
        provider: "google",
        calendar_list: [
          %{"id" => "work", "selected" => true},
          %{"id" => "personal", "selected" => false}
        ]
      )

    google_selected =
      insert(:provider_calendar_event,
        calendar_integration: google,
        all_day: false,
        start_at: DateTime.add(@now, 2, :hour),
        provider_calendar_id: "work",
        provider_event_id: "evt-work"
      )

    google_deselected =
      insert(:provider_calendar_event,
        calendar_integration: google,
        all_day: false,
        start_at: DateTime.add(@now, 3, :hour),
        provider_calendar_id: "personal",
        provider_event_id: "evt-personal"
      )

    # CalDAV-style integration: matched by href prefix. The selected path
    # contains a LIKE metacharacter (`_`) on purpose: a decoy row under a
    # path that differs only where the metacharacter sits must stay excluded
    # unless the prefix is escaped before being used in the `where` clause.
    caldav =
      insert(:calendar_integration,
        is_active: true,
        provider: "caldav",
        calendar_paths: [],
        calendar_list: [
          %{"id" => "/cal/team_a/", "path" => "/cal/team_a/", "selected" => true},
          %{"id" => "/cal/teamb/", "path" => "/cal/teamb/", "selected" => false}
        ]
      )

    caldav_selected =
      insert(:provider_calendar_event,
        calendar_integration: caldav,
        all_day: false,
        start_at: DateTime.add(@now, 4, :hour),
        provider_calendar_id: "/cal/team_a/",
        provider_event_id: "/cal/team_a/evt-c.ics"
      )

    _caldav_like_metachar_decoy =
      insert(:provider_calendar_event,
        calendar_integration: caldav,
        all_day: false,
        start_at: DateTime.add(@now, 5, :hour),
        provider_calendar_id: "/cal/teamXa/",
        provider_event_id: "/cal/teamXa/evt-d.ics"
      )

    # Integration with a selection list but nothing selected: nothing from it
    # is ever visible.
    none_selected =
      insert(:calendar_integration,
        is_active: true,
        provider: "google",
        calendar_list: [%{"id" => "primary", "selected" => false}]
      )

    _none_selected_event =
      insert(:provider_calendar_event,
        calendar_integration: none_selected,
        all_day: false,
        start_at: DateTime.add(@now, 6, :hour),
        provider_calendar_id: "primary",
        provider_event_id: "evt-none"
      )

    # Row whose provider_calendar_id predates the integration's current
    # selection list and matches no entry in it: not a CalDAV href, so it
    # cannot be resolved by prefix either, and stays excluded.
    untagged =
      insert(:calendar_integration,
        is_active: true,
        provider: "google",
        calendar_list: [%{"id" => "cal1", "selected" => true}]
      )

    _untagged_event =
      insert(:provider_calendar_event,
        calendar_integration: untagged,
        all_day: false,
        start_at: DateTime.add(@now, 7, :hour),
        provider_calendar_id: "stale-calendar-id",
        provider_event_id: "evt-untagged"
      )

    integrations = [legacy, google, caldav, none_selected, untagged]
    integration_ids = Enum.map(integrations, & &1.id)

    unfiltered =
      ProviderCalendarEventQueries.list_upcoming_timed(integration_ids, @now, @window_end,
        limit: 100
      )

    expected_ids =
      unfiltered
      |> Selection.visible_events(integrations)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert expected_ids ==
             Enum.sort([legacy_event.id, google_selected.id, caldav_selected.id])

    sql_filtered_ids =
      integration_ids
      |> ProviderCalendarEventQueries.list_upcoming_timed(@now, @window_end,
        limit: 100,
        visibility_rules: Selection.visibility_rules(integrations)
      )
      |> Enum.map(& &1.id)
      |> Enum.sort()

    refute google_deselected.id in sql_filtered_ids
    assert sql_filtered_ids == expected_ids
  end
end
