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

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

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

    test "following on a Google occurrence is refused before anything is written", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})

      assert {:error, %{reason: :unsupported_scope, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
                 recurrence_scope: :following
               )

      refute_received {:provider_update, _uid, _payload, _context}
      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Weekly sync"
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

      assert Enum.sort(Map.keys(changes)) == [:end_time, :start_time, :summary]
      assert changes.summary == "Renamed"
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

      assert %{summary: "Renamed", recurrence_rule: "FREQ=WEEKLY;BYDAY=TU"} = occurrence.changes
      assert Map.has_key?(occurrence.changes, :start_time)
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

      assert %{summary: "Renamed", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;COUNT=4"} = changes
      assert Map.has_key?(changes, :start_time)
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

    test "an occurrence of an Exchange series takes no scope", %{user: user} do
      exchange = insert(:calendar_integration, user: user, provider: "exchange")
      event = insert_event(exchange, exchange_occurrence())

      assert CalendarGrid.edit_scopes(event) == {:error, :recurring_event}
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
