defmodule Tymeslot.CalendarGrid.SeriesEditTest do
  @moduledoc """
  An edit of a member of a recurring series goes through
  `CalendarGrid.update_event/4` with a `RecurrenceScope`, and
  `CalendarGrid.edit_scopes/1` says whether an event takes one. The provider
  write is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`), as in `Tymeslot.CalendarGrid.EventEditTest`.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "google")

    %{user: user, integration: integration}
  end

  # An occurrence of a Google series, named by its master's id.
  defp insert_event(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Weekly sync",
      provider: "google",
      provider_calendar_id: "team-calendar",
      provider_event_id: "/cal/weekly-sync.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      recurrence_rule: "FREQ=WEEKLY;BYDAY=MO",
      recurring_event_id: "series-1",
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  # Captures the payload the provider seam receives and answers `result`.
  defp expect_provider_update(result \\ :ok) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn uid, payload, context ->
      send(test_pid, {:provider_update, uid, payload, context})
      result
    end)
  end

  defp captured_payload do
    assert_received {:provider_update, _uid, payload, _context}
    payload
  end

  describe "update_event/4 on a member of a series" do
    test "an edit of this event only is written to the occurrence's own id", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{provider_event_id: "series-1_20260601T090000Z"})
      expect_provider_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
                 recurrence_scope: :this_only
               )

      assert_received {:provider_update, uid, payload, _context}
      assert uid == event.uid
      assert payload.provider_event_id == "series-1_20260601T090000Z"
      refute Map.has_key?(payload, :recurrence_scope)

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Renamed"
    end

    test "an edit without a scope is an edit of this event only", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{provider_event_id: "series-1_20260601T090000Z"})
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert captured_payload().provider_event_id == "series-1_20260601T090000Z"
    end

    test "following on a Google occurrence is addressed to a split at its original start", %{
      user: user,
      integration: integration
    } do
      # Moved on its own to 11:00 UTC; the series put it at 09:00 UTC.
      event =
        insert_event(integration, %{
          uid: "series-1@google.com_20260601T090000Z",
          provider_event_id: "series-1_20260601T090000Z",
          start_at: ~U[2026-06-01 11:00:00.000000Z],
          end_at: ~U[2026-06-01 12:00:00.000000Z]
        })

      expect_provider_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
                 recurrence_scope: :following
               )

      assert %{
               scope: :following,
               master_id: "series-1",
               slot: ~U[2026-06-01 09:00:00Z],
               start: ~U[2026-06-01 11:00:00.000000Z]
             } = captured_payload().occurrence
    end

    test "following on a Google occurrence whose original start is unknown is refused", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})

      assert {:error, %{reason: :unaddressable_occurrence, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
                 recurrence_scope: :following
               )

      refute_received {:provider_update, _uid, _payload, _context}
      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Weekly sync"
    end

    test "following on a Google occurrence cannot take the repeat rule away", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{provider_event_id: "series-1_20260601T090000Z"})

      assert {:error, %{reason: :unsupported_scope, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{recurrence_rule: nil},
                 recurrence_scope: :following
               )

      refute_received {:provider_update, _uid, _payload, _context}
    end

    test "all on a Google occurrence is addressed to its master, from where it shows now", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{provider_event_id: "series-1_20260601T090000Z"})
      expect_provider_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
                 recurrence_scope: :all
               )

      assert %{
               scope: :all,
               master_id: "series-1",
               start: ~U[2026-06-01 09:00:00.000000Z],
               end: ~U[2026-06-01 10:00:00.000000Z],
               changes: changes
             } = captured_payload().occurrence

      # Timing the rename did not change is not carried as a move.
      assert changes == %{summary: "Renamed"}
    end

    test "a scope that is not a RecurrenceScope raises before anything is written", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})

      assert_raise ArgumentError, ~r/:recurrence_scope/, fn ->
        CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
          recurrence_scope: "this_only"
        )
      end
    end

    test "a failed write is reported as not queued and leaves the row untouched", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})
      expect_provider_update({:error, :server_error})

      assert {:error, %{reason: :server_error, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "synced"
      assert row.summary == "Weekly sync"
    end

    test "this_only on a CalDAV occurrence is addressed to the occurrence", %{user: user} do
      caldav =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      event = insert_event(caldav, Map.merge(caldav_occurrence(), %{provider: "caldav"}))
      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
                 recurrence_scope: :this_only
               )

      assert %{href: "/cal/weekly-sync.ics", key: "20260601T090000"} =
               captured_payload().occurrence

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert row.summary == "Renamed"
    end

    test "following on a CalDAV occurrence is addressed to a split of the series", %{
      user: user
    } do
      caldav =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      event = insert_event(caldav, Map.merge(caldav_occurrence(), %{provider: "caldav"}))
      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      assert {:ok, _updated} =
               CalendarGrid.update_event(
                 user.id,
                 event,
                 %{summary: "Renamed", recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"},
                 recurrence_scope: :following
               )

      assert %{scope: :following, href: "/cal/weekly-sync.ics", key: "20260601T090000"} =
               occurrence = captured_payload().occurrence

      assert occurrence.changes == %{summary: "Renamed", recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"}
    end

    test "following on a CalDAV occurrence cannot take the repeat rule away", %{user: user} do
      caldav =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      event = insert_event(caldav, Map.merge(caldav_occurrence(), %{provider: "caldav"}))

      assert {:error, %{reason: :unsupported_scope, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{recurrence_rule: nil},
                 recurrence_scope: :following
               )

      refute_received {:provider_update, _uid, _payload, _context}
    end

    test "all on a CalDAV occurrence is addressed to the series with its new rule", %{
      user: user
    } do
      caldav =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      event = insert_event(caldav, Map.merge(caldav_occurrence(), %{provider: "caldav"}))
      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      assert {:ok, _updated} =
               CalendarGrid.update_event(
                 user.id,
                 event,
                 %{summary: "Renamed", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=4"},
                 recurrence_scope: :all
               )

      assert %{scope: :all, key: "20260601T090000", changes: changes} =
               captured_payload().occurrence

      assert changes == %{summary: "Renamed", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=4"}
    end

    test "all on a CalDAV occurrence carries the timing of a move, and only then", %{
      user: user
    } do
      caldav =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      event = insert_event(caldav, Map.merge(caldav_occurrence(), %{provider: "caldav"}))
      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      # The same start as the cache's, which moves nothing, and a later end.
      assert {:ok, _updated} =
               CalendarGrid.update_event(
                 user.id,
                 event,
                 %{start_at: event.start_at, end_at: DateTime.add(event.end_at, 30, :minute)},
                 recurrence_scope: :all
               )

      assert %{changes: %{start_time: start, end_time: finish}} = captured_payload().occurrence
      assert DateTime.compare(start, event.start_at) == :eq
      assert DateTime.compare(finish, DateTime.add(event.end_at, 30, :minute)) == :eq
    end

    test "all on a CalDAV occurrence cannot take the repeat rule away", %{user: user} do
      caldav =
        insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

      event = insert_event(caldav, Map.merge(caldav_occurrence(), %{provider: "caldav"}))

      assert {:error, %{reason: :unsupported_scope, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{recurrence_rule: nil},
                 recurrence_scope: :all
               )

      refute_received {:provider_update, _uid, _payload, _context}
    end

    test "an Exchange occurrence is still written to its own item", %{user: user} do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")
      event = insert_event(exchange, exchange_occurrence())
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert captured_payload().provider_event_id == "AAMkAD-occurrence"
    end

    test "all on an Exchange occurrence is refused before anything is written", %{user: user} do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")
      event = insert_event(exchange, exchange_occurrence())

      assert {:error, %{reason: :unsupported_scope, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
                 recurrence_scope: :all
               )

      refute_received {:provider_update, _uid, _payload, _context}
    end
  end

  # A weekly series of ten from Monday 1 June 2026, and its 15 June
  # occurrence: two come before it, so eight are left from it on.
  @series_rule "FREQ=WEEKLY;BYDAY=MO;COUNT=10"
  @every_two_weeks "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;COUNT=10"

  defp counted_occurrence(integration) do
    insert_event(integration, %{
      uid: "series-1@google.com_20260615T090000Z",
      provider_event_id: "series-1_20260615T090000Z",
      start_at: ~U[2026-06-15 09:00:00.000000Z],
      end_at: ~U[2026-06-15 10:00:00.000000Z],
      recurrence_rule: @series_rule
    })
  end

  defp cache_master_start(integration, start) do
    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, "series-1", %{
        rule: @series_rule,
        master_start: start,
        fetched_at: DateTime.utc_now()
      })
  end

  describe "following_rule/3" do
    setup %{integration: integration} do
      %{event: counted_occurrence(integration)}
    end

    test "takes the occurrences before the split off the count", %{
      integration: integration,
      event: event
    } do
      cache_master_start(integration, ~U[2026-06-01 09:00:00Z])

      assert CalendarGrid.following_rule(event, @every_two_weeks, "Etc/UTC") ==
               {:ok, "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;COUNT=8"}
    end

    test "is an end before the occurrence when nothing is left of the count", %{
      integration: integration,
      event: event
    } do
      cache_master_start(integration, ~U[2026-06-01 09:00:00Z])

      assert CalendarGrid.following_rule(event, "FREQ=WEEKLY;BYDAY=MO;COUNT=2", "Etc/UTC") ==
               {:error, :ends_before}
    end

    test "cannot count a series whose first start was never read", %{event: event} do
      assert CalendarGrid.following_rule(event, @every_two_weeks, "Etc/UTC") ==
               {:error, :start_unknown}
    end

    test "leaves a rule without a count as it is", %{event: event} do
      rule = "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;UNTIL=20261231T235959Z"
      assert CalendarGrid.following_rule(event, rule, "Etc/UTC") == {:ok, rule}
    end

    test "keeps the whole count when the split is at the first occurrence", %{
      integration: integration
    } do
      cache_master_start(integration, ~U[2026-06-01 09:00:00Z])

      first =
        insert_event(integration, %{
          uid: "series-1@google.com_20260601T090000Z",
          provider_event_id: "series-1_20260601T090000Z",
          recurrence_rule: @series_rule
        })

      assert CalendarGrid.following_rule(first, @every_two_weeks, "Etc/UTC") ==
               {:ok, @every_two_weeks}
    end

    # 09:00 in Berlin is 07:00Z until the clocks go back on 25 October and
    # 08:00Z after, so counted in UTC the occurrence of 2 November would
    # have three before it rather than two.
    test "counts the occurrences on the wall clock of the series' zone across a DST change",
         %{integration: integration} do
      cache_master_start(integration, ~U[2026-10-19 07:00:00Z])

      after_the_change =
        insert_event(integration, %{
          uid: "series-1@google.com_20261102T080000Z",
          provider_event_id: "series-1_20261102T080000Z",
          start_at: ~U[2026-11-02 08:00:00.000000Z],
          end_at: ~U[2026-11-02 09:00:00.000000Z],
          recurrence_rule: @series_rule
        })

      assert CalendarGrid.following_rule(after_the_change, @series_rule, "Europe/Berlin") ==
               {:ok, "FREQ=WEEKLY;BYDAY=MO;COUNT=8"}

      assert CalendarGrid.following_rule(after_the_change, @series_rule, "Etc/UTC") ==
               {:ok, "FREQ=WEEKLY;BYDAY=MO;COUNT=7"}
    end
  end

  describe "update_event/4 of a counted rule" do
    setup %{integration: integration} do
      %{event: counted_occurrence(integration)}
    end

    # The series may have changed since the rule was chosen: what is left
    # is counted from it as it is when the edit is written.
    test "following writes what is left of the series as it is then", %{
      user: user,
      integration: integration,
      event: event
    } do
      cache_master_start(integration, ~U[2026-06-08 09:00:00Z])
      expect_provider_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{recurrence_rule: @every_two_weeks},
                 recurrence_scope: :following,
                 until_timezone: "Etc/UTC"
               )

      payload = captured_payload()
      assert payload.recurrence_rule == "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO;COUNT=9"
      assert payload.occurrence.changes.recurrence_rule == payload.recurrence_rule
    end

    test "following is refused when nothing is left of the count", %{
      user: user,
      integration: integration,
      event: event
    } do
      cache_master_start(integration, ~U[2026-06-01 09:00:00Z])

      assert {:error, %{reason: :ends_before, retry: :not_queued}} =
               CalendarGrid.update_event(
                 user.id,
                 event,
                 %{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=2"},
                 recurrence_scope: :following
               )

      refute_received {:provider_update, _uid, _payload, _context}
    end

    test "following is refused when the series' first start was never read", %{
      user: user,
      event: event
    } do
      assert {:error, %{reason: :start_unknown, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{recurrence_rule: @every_two_weeks},
                 recurrence_scope: :following
               )

      refute_received {:provider_update, _uid, _payload, _context}
    end

    # The prompt was opened on a member of the series; a sync since made
    # the cached event a one-off. Writing the rule there would start a new
    # series of the whole count from this event.
    test "following is refused when a sync has made the event a one-off", %{
      user: user,
      integration: integration,
      event: event
    } do
      cache_master_start(integration, ~U[2026-06-01 09:00:00Z])

      event
      |> Changeset.change(recurrence_rule: nil, recurring_event_id: nil)
      |> Repo.update!()

      assert {:error, %{reason: :ends_before, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{recurrence_rule: @every_two_weeks},
                 recurrence_scope: :following
               )

      refute_received {:provider_update, _uid, _payload, _context}

      assert {:ok, %{recurrence_rule: nil}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
    end

    test "all writes the count as given", %{
      user: user,
      integration: integration,
      event: event
    } do
      cache_master_start(integration, ~U[2026-06-01 09:00:00Z])
      expect_provider_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{recurrence_rule: @every_two_weeks},
                 recurrence_scope: :all
               )

      assert captured_payload().recurrence_rule == @every_two_weeks
    end
  end

  describe "edit_scopes/1" do
    test "a one-off event is edited on its own", %{integration: integration} do
      event = insert_event(integration, %{recurrence_rule: nil, recurring_event_id: nil})

      assert CalendarGrid.edit_scopes(event) == {:ok, :single}
    end

    test "an occurrence of a Google series takes a scope", %{integration: integration} do
      assert CalendarGrid.edit_scopes(insert_event(integration, %{})) == {:ok, :series}
    end

    test "an occurrence of a CalDAV series takes a scope", %{user: user} do
      caldav = insert(:calendar_integration, user: user, provider: "caldav")
      event = insert_event(caldav, Map.merge(caldav_occurrence(), %{provider: "caldav"}))

      assert CalendarGrid.edit_scopes(event) == {:ok, :series}
    end

    test "an occurrence of an Exchange series is edited as that event only", %{user: user} do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")
      event = insert_event(exchange, exchange_occurrence())

      assert CalendarGrid.edit_scopes(event) == {:ok, :this_only}
    end

    test "reads the series from the cached row when handed only the address", %{
      integration: integration
    } do
      event = insert_event(integration, %{})
      address = %{uid: event.uid, calendar_integration_id: integration.id}

      assert CalendarGrid.edit_scopes(address) == {:ok, :series}
    end
  end

  # An expanded CalDAV occurrence: the series' href and repeat rule, and its
  # series' UID followed by the occurrence's key.
  defp caldav_occurrence do
    %{
      uid: "weekly-sync_20260601T090000",
      provider_event_id: "/cal/weekly-sync.ics",
      recurring_event_id: nil,
      provider_metadata: %{"uid" => "weekly-sync"}
    }
  end

  # An Exchange occurrence names no master; only its item type says it
  # belongs to a series.
  defp exchange_occurrence do
    %{
      provider: "exchange",
      provider_calendar_id: "calendar",
      provider_event_id: "AAMkAD-occurrence",
      recurrence_rule: nil,
      recurring_event_id: nil,
      provider_metadata: %{"calendar_item_type" => "Occurrence"}
    }
  end
end
