defmodule Tymeslot.CalendarGrid.EventEditRecurringTest do
  @moduledoc """
  `CalendarGrid.update_event/4` against an event that belongs to a repeating
  series on the CalDAV family.

  The sync never stores such a series' master: it expands it into one cached
  row per occurrence, all sharing the series' href, and the writer patches
  that master. Because the payload is always the complete event, it carries
  the occurrence's own `DTSTART` with it, so a rename relocates the series
  onto that occurrence's date exactly as a drag would. Every edit is
  therefore refused before the provider seam, and what is pinned here is that
  the refusal is scoped: it catches the series markers a CalDAV sync can
  produce, and nothing outside the family.

  The provider write is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`); under `verify_on_exit!` a write that reached it
  without an expectation fails the test, which is how "nothing was written"
  is asserted.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  @rrule "FREQ=WEEKLY;BYDAY=MO"

  setup do
    user = insert(:user)

    caldav =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    %{user: user, caldav: caldav}
  end

  describe "an occurrence of a CalDAV series" do
    for {kind, changes} <- [
          reschedule:
            quote(do: %{start_at: ~U[2026-06-01 11:00:00Z], end_at: ~U[2026-06-01 12:00:00Z]}),
          rename: quote(do: %{summary: "Renamed"}),
          colour: quote(do: %{colour: "grape"})
        ] do
      test "a #{kind} is refused before anything is written", %{user: user, caldav: caldav} do
        event = insert_event(caldav, %{recurrence_rule: @rrule})

        assert {:error, %{reason: :recurring_event, retry: :not_queued}} =
                 CalendarGrid.update_event(user.id, event, unquote(changes))

        {:ok, row} = ProviderCalendarEventQueries.get_by_uid(caldav.id, event.uid)
        assert row.summary == "Weekly sync"
        assert row.colour == "tomato"
        assert row.start_at == ~U[2026-06-01 09:00:00.000000Z]
      end
    end

    test "one already edited on its own is refused too", %{user: user, caldav: caldav} do
      # A detached override: no repeat rule of its own, named only by the
      # recurrence id the sync keeps in `provider_metadata`. It lives in the
      # series' resource all the same, and the patcher skips it, so a write
      # against it lands on the master.
      event =
        insert_event(caldav, %{provider_metadata: %{"recurrence_id" => "20260601T090000"}})

      assert {:error, %{reason: :recurring_event}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
    end

    test "is refused on the strength of the cached row, not the copy passed in", %{
      user: user,
      caldav: caldav
    } do
      event = insert_event(caldav, %{recurrence_rule: @rrule})

      # What a LiveView holds mid-drag, or what a caller outside the grid
      # could construct: the repeat rule edited away.
      assert {:error, %{reason: :recurring_event}} =
               CalendarGrid.update_event(user.id, %{event | recurrence_rule: nil}, %{
                 summary: "Renamed"
               })
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

  defp expect_provider_update do
    expect(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)
  end
end
