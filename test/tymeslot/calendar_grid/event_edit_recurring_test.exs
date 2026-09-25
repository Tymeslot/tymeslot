defmodule Tymeslot.CalendarGrid.EventEditRecurringTest do
  @moduledoc """
  `CalendarGrid.update_event/4` against an event that belongs to a repeating
  series on the CalDAV family.

  The sync never stores such a series' master: it expands it into one cached
  row per occurrence, all sharing the series' href. The ordinary write
  patches that master, so an edit of one occurrence is addressed instead: the
  payload carries an `:occurrence` naming the series' href and the
  occurrence's key, and only what the edit changed plus the occurrence's
  timing, which the CalDAV writer turns into a `RECURRENCE-ID` override.
  What is pinned here is that addressing, read off the cached row, and the
  edits refused before anything is written because they are not edits of one
  occurrence.

  The provider write is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`); under `verify_on_exit!` a write that reached it
  without an expectation fails the test, which is how "nothing was written"
  is asserted. `EventEditCalDAVWriteTest` takes the same edit down to the
  wire.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  @rrule "FREQ=WEEKLY;BYDAY=MO"
  @series_document "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nUID:weekly-sync\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

  setup do
    user = insert(:user)

    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    %{user: user, caldav: caldav}
  end

  describe "an occurrence of a CalDAV series" do
    test "a rename is addressed to the occurrence, with only the change and its timing", %{
      user: user,
      caldav: caldav
    } do
      event = insert_occurrence(caldav, %{})
      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      assert_received {:provider_update, uid, payload}
      assert uid == event.uid

      assert payload.occurrence == %{
               href: "/cal/weekly-sync.ics",
               key: "20260601T110000",
               scope: :this_only,
               timezone: "Europe/Berlin",
               document: @series_document,
               etag: "\"etag-1\"",
               changes: %{
                 summary: "Renamed",
                 start_time: ~U[2026-06-01 09:00:00.000000Z],
                 end_time: ~U[2026-06-01 10:00:00.000000Z]
               }
             }

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert {row.summary, row.raw_ical, row.etag} == {"Renamed", "NEW DOCUMENT", nil}
    end

    test "the rest of the series is given the document the provider answered with", %{
      user: user,
      caldav: caldav
    } do
      event = insert_occurrence(caldav, %{})
      sibling = insert_occurrence(caldav, %{uid: "weekly-sync_20260608T110000"})
      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{
                 start_at: ~U[2026-06-01 11:00:00Z],
                 end_at: ~U[2026-06-01 12:00:00Z]
               })

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, sibling.uid)

      assert {row.raw_ical, row.etag, row.start_at} ==
               {"NEW DOCUMENT", nil, ~U[2026-06-01 09:00:00.000000Z]}
    end

    test "one already edited on its own is addressed by its own key", %{
      user: user,
      caldav: caldav
    } do
      # A detached override: no repeat rule of its own, named only by the
      # recurrence id the sync keeps in `provider_metadata`.
      event =
        insert_occurrence(caldav, %{
          uid: "weekly-sync_20260615T110000",
          recurrence_rule: nil,
          provider_metadata: %{"uid" => "weekly-sync", "recurrence_id" => "20260615T110000"}
        })

      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{colour: "grape"})

      assert_received {:provider_update, _uid, %{occurrence: occurrence}}
      assert occurrence.key == "20260615T110000"
      assert occurrence.changes.colour == "grape"
    end

    test "is addressed on the strength of the cached row, not the copy passed in", %{
      user: user,
      caldav: caldav
    } do
      event = insert_occurrence(caldav, %{})
      expect_provider_update({:ok, %{document: "NEW DOCUMENT"}})

      # What a LiveView holds mid-drag, or what a caller outside the grid
      # could construct: the repeat rule edited away.
      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, %{event | recurrence_rule: nil}, %{
                 summary: "Renamed"
               })

      assert_received {:provider_update, _uid, %{occurrence: %{key: "20260601T110000"}}}
    end

    for {kind, {changes, reason}} <- [
          repeat_rule: {quote(do: %{recurrence_rule: "FREQ=DAILY"}), :unsupported_scope},
          all_day:
            {quote(
               do: %{
                 all_day: true,
                 start_at: nil,
                 end_at: nil,
                 start_date: ~D[2026-06-01],
                 end_date: ~D[2026-06-02]
               }
             ), :value_type_change}
        ] do
      test "a change of #{kind} is refused before anything is written", %{
        user: user,
        caldav: caldav
      } do
        event = insert_occurrence(caldav, %{})

        assert {:error, %{reason: unquote(reason), retry: :not_queued}} =
                 CalendarGrid.update_event(user.id, event, unquote(changes))

        {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
        assert {row.all_day, row.recurrence_rule} == {false, @rrule}
      end
    end

    test "a row that does not name its occurrence is refused", %{user: user, caldav: caldav} do
      # No series UID to strip, so no key to find the occurrence by.
      event = insert_occurrence(caldav, %{provider_metadata: %{}})

      assert {:error, %{reason: :unaddressable_occurrence, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
    end

    test "a failed write is not queued and leaves the row as it was", %{
      user: user,
      caldav: caldav
    } do
      event = insert_occurrence(caldav, %{})
      expect_provider_update({:error, :network_error})

      assert {:error, %{reason: :network_error, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert {row.summary, row.sync_state} == {"Weekly sync", "synced"}
    end
  end

  describe "an event the writer can address on its own" do
    test "a one-off CalDAV event on the same calendar is written", %{
      user: user,
      caldav: caldav
    } do
      event = insert_event(caldav, %{})
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
      assert row.summary == "Renamed"
    end

    test "a Google occurrence is written, because Google addresses it by id", %{user: user} do
      google = insert(:calendar_integration, user: user, provider: "google")

      event =
        insert_event(google, %{
          provider: "google",
          provider_calendar_id: "primary",
          recurrence_rule: @rrule,
          recurring_event_id: "series-1"
        })

      expect_provider_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{
                 start_at: ~U[2026-06-01 11:00:00Z],
                 end_at: ~U[2026-06-01 12:00:00Z]
               })

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(google.id, event.uid)
      assert row.start_at == ~U[2026-06-01 11:00:00.000000Z]
    end
  end

  defp insert_event(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Weekly sync",
      provider: "caldav",
      provider_calendar_id: "team-calendar",
      provider_event_id: "/cal/weekly-sync.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      colour: "tomato",
      etag: "\"etag-1\"",
      raw_ical: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n",
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  # An expanded occurrence of a Berlin series: 11:00 local on 1 June.
  defp insert_occurrence(integration, attrs) do
    insert_event(
      integration,
      Map.merge(
        %{
          uid: "weekly-sync_20260601T110000",
          timezone: "Europe/Berlin",
          recurrence_rule: @rrule,
          provider_metadata: %{"uid" => "weekly-sync"},
          raw_ical: @series_document
        },
        attrs
      )
    )
  end

  defp expect_provider_update(result \\ :ok) do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:provider_update, uid, payload})
      result
    end)
  end
end
