defmodule Tymeslot.CalendarGrid.EventEditTest do
  @moduledoc """
  `CalendarGrid.update_event/4` applies one change to the whole event, writes
  that whole event to the provider, and records the edit on the cached row
  without touching the columns the provider owns.

  The provider write is stubbed at the suite-wide `:calendar_module` seam
  (`Tymeslot.CalendarMock`), which is where `Calendar.Events.update_event/3`
  dispatches. The payloads it captures are also fed through the real Google,
  Outlook and CalDAV mappers, so the keys and timing types pinned here are the
  ones those adapters actually read.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.Google.EventMapper, as: GoogleMapper
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.Outlook.EventMapper, as: OutlookMapper
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  @attendees [%{"email" => "guest@example.com", "name" => "Guest", "status" => "accepted"}]
  @reminders [%{method: :popup, minutes_before: 15}]
  @rrule "FREQ=WEEKLY;BYDAY=MO"
  # The same series ending on the same day, in each of the two UNTIL value
  # types RFC 5545 §3.3.10 allows: a UTC timestamp for a timed DTSTART, a bare
  # date for an all-day one.
  @timed_rrule "FREQ=WEEKLY;BYDAY=MO;UNTIL=20261231T235959Z"
  @all_day_rrule "FREQ=WEEKLY;BYDAY=MO;UNTIL=20261231"
  @raw_ical "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

    %{user: user, integration: integration}
  end

  defp insert_event(integration, attrs) do
    defaults = %{
      calendar_integration: integration,
      uid: "event-#{System.unique_integer([:positive])}",
      summary: "Weekly sync",
      description: "Agenda",
      location: "Room 4",
      provider: "caldav",
      provider_calendar_id: "team-calendar",
      provider_event_id: "/cal/weekly-sync.ics",
      start_at: ~U[2026-06-01 09:00:00.000000Z],
      end_at: ~U[2026-06-01 10:00:00.000000Z],
      all_day: false,
      attendees: @attendees,
      reminders: @reminders,
      recurrence_rule: @rrule,
      recurrence_exceptions: [~D[2026-06-08]],
      colour: "tomato",
      transparency: "transparent",
      visibility: "private",
      recurring_event_id: "series-1",
      etag: "\"etag-1\"",
      raw_ical: @raw_ical,
      video_link: "https://video.example.com/room",
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp insert_all_day_event(integration, attrs \\ %{}) do
    insert_event(
      integration,
      Map.merge(
        %{
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-06-01],
          end_date: ~D[2026-06-02]
        },
        attrs
      )
    )
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

  describe "update_event/4 provider payload" do
    for {kind, changes} <- [
          summary: quote(do: %{summary: "Renamed"}),
          description: quote(do: %{description: "New agenda"}),
          location: quote(do: %{location: "Room 9"}),
          timing:
            quote(do: %{start_at: ~U[2026-06-01 11:00:00Z], end_at: ~U[2026-06-01 12:00:00Z]}),
          colour: quote(do: %{colour: "grape"}),
          reminders: quote(do: %{reminders: [%{method: :email, minutes_before: 30}]}),
          recurrence_rule: quote(do: %{recurrence_rule: "FREQ=DAILY"}),
          attendees: quote(do: %{attendees: [%{"email" => "new@example.com", "name" => nil}]})
        ] do
      test "a #{kind} edit sends the whole updated event", %{
        user: user,
        integration: integration
      } do
        changes = unquote(changes)
        event = insert_event(integration, %{})
        expect_provider_update()

        assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, changes)

        assert_received {:provider_update, uid, payload, context}
        assert uid == event.uid
        assert context == {integration.id, user.id}

        expected =
          Map.merge(
            %{
              summary: "Weekly sync",
              description: "Agenda",
              location: "Room 4",
              start_time: ~U[2026-06-01 09:00:00.000000Z],
              end_time: ~U[2026-06-01 10:00:00.000000Z],
              all_day: false,
              attendees: @attendees,
              reminders: @reminders,
              recurrence_rule: @rrule,
              recurrence_exceptions: [~D[2026-06-08]],
              colour: "tomato",
              transparency: "transparent",
              visibility: "private",
              status: "confirmed",
              provider_event_id: "/cal/weekly-sync.ics",
              calendar_id: "team-calendar",
              # The document the provider last gave us travels with the
              # payload, for the adapters that patch it rather than rebuild
              # the event from what the cache models.
              raw_ical: @raw_ical,
              etag: "\"etag-1\""
            },
            payload_changes(changes)
          )

        assert payload == expected
      end
    end

    test "an event that has never synced sends no stored document", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{raw_ical: nil, etag: nil})
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      payload = captured_payload()
      refute Map.has_key?(payload, :raw_ical)
      refute Map.has_key?(payload, :etag)
    end

    test "the stored document is read from the cache row, not from the event passed in", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})
      expect_provider_update()

      # What the grid hands over is whatever it last assigned, which may be an
      # optimistic copy built from a form. A document taken from that would be
      # missing, and the write would silently rebuild the event instead of
      # patching it.
      optimistic = %{event | raw_ical: nil, etag: nil}

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, optimistic, %{summary: "Renamed"})

      payload = captured_payload()
      assert payload.raw_ical == @raw_ical
      assert payload.etag == "\"etag-1\""
    end

    test "toggling a timed event to all-day sends Date timing and keeps everything else", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})
      expect_provider_update()

      changes = %{all_day: true, start_date: ~D[2026-06-01], end_date: ~D[2026-06-02]}

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, changes)
      assert {updated.start_at, updated.end_at} == {nil, nil}

      payload = captured_payload()
      assert payload.start_time == ~D[2026-06-01]
      assert payload.end_time == ~D[2026-06-02]
      assert payload.all_day == true
      assert payload.attendees == @attendees
      assert payload.reminders == @reminders
      assert payload.recurrence_rule == @rrule
      assert payload.colour == "tomato"

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert {row.start_at, row.end_at} == {nil, nil}
    end

    test "toggling an all-day event to timed sends DateTime timing and drops the dates", %{
      user: user,
      integration: integration
    } do
      event = insert_all_day_event(integration)
      expect_provider_update()

      changes = %{
        all_day: false,
        start_at: ~U[2026-06-01 09:00:00Z],
        end_at: ~U[2026-06-01 10:00:00Z]
      }

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, changes)

      payload = captured_payload()
      assert payload.start_time == ~U[2026-06-01 09:00:00Z]
      assert payload.end_time == ~U[2026-06-01 10:00:00Z]
      assert payload.all_day == false

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert {row.start_date, row.end_date} == {nil, nil}
      assert row.start_at == ~U[2026-06-01 09:00:00.000000Z]
    end

    test "adding an attendee to an all-day event keeps its Date timing", %{
      user: user,
      integration: integration
    } do
      event = insert_all_day_event(integration)
      expect_provider_update()

      attendees = @attendees ++ [%{"email" => "late@example.com", "name" => nil}]
      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{attendees: attendees})

      payload = captured_payload()
      assert payload.start_time == ~D[2026-06-01]
      assert payload.end_time == ~D[2026-06-02]
      assert payload.all_day == true
      assert payload.attendees == attendees
    end

    test "an event on the placeholder \"primary\" calendar leaves the calendar to the provider",
         %{user: user, integration: integration} do
      event = insert_event(integration, %{provider_calendar_id: "primary"})
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert captured_payload().calendar_id == nil
    end

    test "a declined status is not written back as the event's status", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{status: "declined"})
      expect_provider_update()

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert captured_payload().status == nil
    end

    test "forwards the recurrence scope", %{user: user, integration: integration} do
      event = insert_event(integration, %{})
      expect_provider_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"},
                 recurrence_scope: "all"
               )

      assert captured_payload().recurrence_scope == "all"
    end
  end

  describe "update_event/4 on a recurring series that changes all-day" do
    test "toggling a timed series to all-day refits its UNTIL to a bare date", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{recurrence_rule: @timed_rrule})
      expect_provider_update()

      changes = %{all_day: true, start_date: ~D[2026-06-01], end_date: ~D[2026-06-02]}

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, changes)
      assert updated.recurrence_rule == @all_day_rrule
      assert captured_payload().recurrence_rule == @all_day_rrule

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.recurrence_rule == @all_day_rrule
    end

    test "toggling an all-day series to timed refits its UNTIL to a UTC timestamp", %{
      user: user,
      integration: integration
    } do
      event = insert_all_day_event(integration, %{recurrence_rule: @all_day_rrule})
      expect_provider_update()

      changes = %{
        all_day: false,
        start_at: ~U[2026-06-01 09:00:00Z],
        end_at: ~U[2026-06-01 10:00:00Z]
      }

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, changes)
      assert updated.recurrence_rule == @timed_rrule
      assert captured_payload().recurrence_rule == @timed_rrule

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.recurrence_rule == @timed_rrule
    end

    test "a toggle to timed ends the UNTIL day in the organiser's timezone", %{
      user: user,
      integration: integration
    } do
      event = insert_all_day_event(integration, %{recurrence_rule: @all_day_rrule})
      expect_provider_update()

      changes = %{
        all_day: false,
        start_at: ~U[2026-06-01 09:00:00Z],
        end_at: ~U[2026-06-01 10:00:00Z]
      }

      assert {:ok, updated} =
               CalendarGrid.update_event(user.id, event, changes, timezone: "America/Los_Angeles")

      # 31 Dec 23:59:59 in Los Angeles is 1 Jan 07:59:59 UTC, so the final
      # occurrence on 31 December local is still inside the bound.
      assert updated.recurrence_rule == "FREQ=WEEKLY;BYDAY=MO;UNTIL=20270101T075959Z"
    end

    test "a toggle back to all-day keeps the date the organiser picked", %{
      user: user,
      integration: integration
    } do
      event =
        insert_event(integration, %{
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO;UNTIL=20270101T075959Z"
        })

      expect_provider_update()

      changes = %{all_day: true, start_date: ~D[2026-06-01], end_date: ~D[2026-06-02]}

      assert {:ok, updated} =
               CalendarGrid.update_event(user.id, event, changes, timezone: "America/Los_Angeles")

      assert updated.recurrence_rule == @all_day_rrule
    end

    test "a toggle that would end the series before it starts is refused", %{
      user: user,
      integration: integration
    } do
      dead_rule = "FREQ=WEEKLY;BYDAY=MO;UNTIL=20260501"
      event = insert_all_day_event(integration, %{recurrence_rule: dead_rule})

      changes = %{
        all_day: false,
        start_at: ~U[2026-06-01 09:00:00Z],
        end_at: ~U[2026-06-01 10:00:00Z]
      }

      assert {:error, %{reason: :until_before_start, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, changes)

      refute_received {:provider_update, _uid, _payload, _context}

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.recurrence_rule == dead_rule
      assert row.all_day == true
      assert row.sync_state == "synced"
    end

    test "an edit that leaves all-day alone does not touch the rule", %{
      user: user,
      integration: integration
    } do
      # Wrong value type for a timed event and ending before it starts: an
      # unrelated edit still goes through, untouched, rather than being
      # rewritten or refused.
      odd_rule = "FREQ=WEEKLY;BYDAY=MO;UNTIL=20260501"
      event = insert_event(integration, %{recurrence_rule: odd_rule})
      expect_provider_update()

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert updated.recurrence_rule == odd_rule
      assert captured_payload().recurrence_rule == odd_rule
    end
  end

  describe "update_event/4 payloads through the provider mappers" do
    setup %{user: user, integration: integration} do
      expect_provider_update()
      expect_provider_update()

      timed = insert_event(integration, %{})
      all_day = insert_all_day_event(integration)

      {:ok, _updated} = CalendarGrid.update_event(user.id, timed, %{summary: "Renamed"})
      timed_payload = captured_payload()

      {:ok, _updated} = CalendarGrid.update_event(user.id, all_day, %{summary: "Renamed"})
      all_day_payload = captured_payload()

      %{timed_payload: timed_payload, all_day_payload: all_day_payload}
    end

    test "Google receives attendees, reminders, recurrence, colour and date-only timing", %{
      timed_payload: timed_payload,
      all_day_payload: all_day_payload
    } do
      body = GoogleMapper.format_event_data(timed_payload)

      assert body["summary"] == "Renamed"
      assert body["attendees"] == [%{"email" => "guest@example.com", "displayName" => "Guest"}]
      assert body["reminders"]["overrides"] == [%{"method" => "popup", "minutes" => 15}]
      assert body["recurrence"] == ["RRULE:#{@rrule}"]
      assert body["colorId"] == "11"
      assert body["transparency"] == "transparent"
      assert body["visibility"] == "private"
      assert Map.has_key?(body["start"], "dateTime")

      all_day_body = GoogleMapper.format_event_data(all_day_payload)
      assert all_day_body["start"] == %{"date" => "2026-06-01"}
      assert all_day_body["end"] == %{"date" => "2026-06-02"}
    end

    test "Outlook receives attendees, reminder, recurrence and an all-day flag", %{
      timed_payload: timed_payload,
      all_day_payload: all_day_payload
    } do
      body = OutlookMapper.format_event_data(timed_payload)

      assert [%{"emailAddress" => %{"address" => "guest@example.com"}}] = body["attendees"]
      assert body["reminderMinutesBeforeStart"] == 15
      assert body["recurrence"]["pattern"]["daysOfWeek"] == ["monday"]
      assert body["showAs"] == "free"
      refute Map.has_key?(body, "isAllDay")

      assert OutlookMapper.format_event_data(all_day_payload)["isAllDay"] == true
    end

    test "CalDAV rebuilds the VEVENT with every modelled property", %{
      timed_payload: timed_payload,
      all_day_payload: all_day_payload
    } do
      ical = ICalBuilder.build_simple_event("uid-1", timed_payload)

      assert ical =~ "SUMMARY:Renamed"
      assert ical =~ "CONTACT:Guest <guest@example.com>"
      assert ical =~ "RRULE:#{@rrule}"
      assert ical =~ "EXDATE:20260608T090000Z"
      assert ical =~ "TRIGGER:-PT15M"
      assert ical =~ "COLOR:tomato"
      assert ical =~ "TRANSP:TRANSPARENT"
      assert ical =~ "CLASS:PRIVATE"

      all_day_ical = ICalBuilder.build_simple_event("uid-2", all_day_payload)
      assert all_day_ical =~ "DTSTART;VALUE=DATE:20260601"
      assert all_day_ical =~ "DTEND;VALUE=DATE:20260602"
    end
  end

  describe "update_event/4 after a successful write" do
    test "records the edit and keeps the columns the provider owns", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})
      expect_provider_update()

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert updated.summary == "Renamed"

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.summary == "Renamed"
      assert row.recurring_event_id == "series-1"
      assert row.etag == "\"etag-1\""
      assert row.raw_ical == "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"
      assert row.video_link == "https://video.example.com/room"
      assert row.attendees == @attendees
      assert row.recurrence_rule == @rrule
      assert row.sync_state == "synced"
    end

    test "invalidates the organiser's cached availability", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})
      expect_provider_update()

      key = AvailabilityCache.booking_window_events_key(user.id)
      :ok = AvailabilityCache.put(key, :stale)

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end
  end

  describe "update_event/4 when the provider write fails" do
    test "a recoverable CalDAV failure is queued and the edit kept locally", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})
      expect_provider_update({:error, :server_error})

      changes = %{
        all_day: true,
        start_date: ~D[2026-06-01],
        end_date: ~D[2026-06-02],
        start_at: nil,
        end_at: nil
      }

      assert {:error, %{reason: :server_error, retry: :queued}} =
               CalendarGrid.update_event(user.id, event, changes)

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "locally_modified"
      assert row.all_day == true
      assert {row.start_date, row.end_date} == {~D[2026-06-01], ~D[2026-06-02]}
      assert row.attendees == @attendees
    end

    test "an unauthorised write is not queued and leaves the row untouched", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})
      expect_provider_update({:error, :unauthorized})

      assert {:error, %{reason: :unauthorized, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.sync_state == "synced"
      assert row.summary == "Weekly sync"
    end

    test "a provider without an offline queue reports the failure as not queued", %{
      user: user
    } do
      google = insert(:calendar_integration, user: user, provider: "google")
      event = insert_event(google, %{provider: "google"})
      expect_provider_update({:error, :server_error})

      assert {:error, %{reason: :server_error, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(google.id, event.uid)
      assert row.sync_state == "synced"
      assert row.summary == "Weekly sync"
    end
  end

  describe "update_event/4 input guards" do
    test "an unknown change key raises before anything is written", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})

      assert_raise ArgumentError, ~r/:etag/, fn ->
        CalendarGrid.update_event(user.id, event, %{summary: "Renamed", etag: "forged"})
      end
    end

    test "an all-day event without dates never reaches the provider", %{
      user: user,
      integration: integration
    } do
      event = insert_event(integration, %{})

      assert {:error, %{reason: :invalid_timing, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, event, %{all_day: true})
    end
  end

  # The payload keys a change in cache vocabulary lands on.
  defp payload_changes(%{start_at: start_at, end_at: end_at}),
    do: %{start_time: start_at, end_time: end_at}

  defp payload_changes(changes), do: changes
end
