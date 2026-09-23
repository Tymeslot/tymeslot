defmodule Tymeslot.CalendarGrid.EventEditCalDAVWriteTest do
  @moduledoc """
  What a grid edit of a synced CalDAV event actually puts on the wire.

  `EventEditTest` stops at the `:calendar_module` seam and pins the payload;
  this module points that seam back at the runtime module so the edit travels
  the whole way down — grid domain, provider adapter, CalDAV writer — and the
  iCalendar document the server receives can be read.

  The journey is worth its cost because the loss it guards against is
  invisible from either end. The payload is complete, the write succeeds, and
  the organiser's rename lands; it is only in the document that an event
  created in another client comes back with its participants replaced by
  `CONTACT` lines and their invitations dropped.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries

  setup :verify_on_exit!

  @attendee_ada "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada:mailto:ada@example.com"
  @attendee_bob "ATTENDEE;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:bob@example.com"

  # The event as it arrived from the server: written in another client, with
  # two attendees who have already answered.
  @synced_ical """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  PRODID:-//Mozilla.org/NONSGML Mozilla Calendar V1.1//EN\r
  BEGIN:VEVENT\r
  UID:sprint-review\r
  DTSTAMP:20260901T090000Z\r
  DTSTART:20260910T090000Z\r
  DTEND:20260910T100000Z\r
  SUMMARY:Sprint review\r
  CATEGORIES:WORK\r
  #{@attendee_ada}\r
  #{@attendee_bob}\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module do
        Application.put_env(:tymeslot, :calendar_module, previous_module)
      else
        Application.delete_env(:tymeslot, :calendar_module)
      end
    end)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/"]
      )

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "sprint-review",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/sprint-review.ics",
        summary: "Sprint review",
        start_at: ~U[2026-09-10 09:00:00.000000Z],
        end_at: ~U[2026-09-10 10:00:00.000000Z],
        all_day: false,
        attendees: [%{"email" => "ada@example.com", "name" => "Ada", "status" => "accepted"}],
        etag: "\"etag-1\"",
        raw_ical: @synced_ical,
        sync_state: "synced"
      )

    %{user: user, integration: integration, event: event}
  end

  describe "renaming a synced CalDAV event from the grid" do
    test "sends the stored document with only the title rewritten", %{
      user: user,
      event: event
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
        send(test_pid, {:put, url, body, headers})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})
      assert updated.summary == "Renamed"

      assert_received {:put, url, body, headers}
      lines = LineFolder.unfold_lines(body)

      # The attendees the organiser never touched, with the responses they
      # gave, exactly as the server had them.
      assert @attendee_ada in lines
      assert @attendee_bob in lines
      refute body =~ "CONTACT:"

      assert "SUMMARY:Renamed" in lines
      assert "CATEGORIES:WORK" in lines
      assert url == "https://caldav.example.com/cal/sprint-review.ics"
      assert {"If-Match", "\"etag-1\""} in headers
    end

    test "leaves the cached document and ETag for the next write to use", %{
      user: user,
      integration: integration,
      event: event
    } do
      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{summary: "Renamed"})

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
      assert row.raw_ical == @synced_ical
      assert row.etag == "\"etag-1\""
      assert row.summary == "Renamed"
    end
  end

  # The grid removes a guest by writing the shortened list
  # (`AttendeeManagement.apply_remove_attendee/3`). The guest has already been
  # emailed a cancellation by then, so a document that kept her line would put
  # her back in the grid on the next sync.
  describe "changing the guests of a synced CalDAV event from the grid" do
    defp expect_put do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn _url, body, _headers, _opts ->
        send(test_pid, {:put, body})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)
    end

    defp sent_attendee_lines do
      assert_received {:put, body}
      body |> LineFolder.unfold_lines() |> Enum.filter(&String.starts_with?(&1, "ATTENDEE"))
    end

    test "removing a guest takes her ATTENDEE line off the server's document", %{
      user: user,
      event: event
    } do
      expect_put()

      # The list the grid sends once Bob is removed from a cache that held both.
      remaining = [%{"email" => "ada@example.com", "name" => "Ada", "status" => "accepted"}]
      assert {:ok, updated} = CalendarGrid.update_event(user.id, event, %{attendees: remaining})
      assert updated.attendees == remaining

      # Ada's reply travels with her, verbatim, rather than being rebuilt from
      # the cache, which holds no ROLE for her.
      assert sent_attendee_lines() == [@attendee_ada]
    end

    test "adding a guest writes a client-scheduled ATTENDEE and keeps the others' replies", %{
      user: user,
      event: event
    } do
      expect_put()

      attendees = [
        %{"email" => "ada@example.com", "name" => "Ada", "status" => "accepted"},
        %{"email" => "bob@example.com", "name" => nil, "status" => "accepted"},
        %{"email" => "cleo@example.com", "name" => nil, "status" => "needs_action"}
      ]

      assert {:ok, _updated} = CalendarGrid.update_event(user.id, event, %{attendees: attendees})

      # SCHEDULE-AGENT=CLIENT: stored, but not mailed by the server, because
      # Tymeslot has already sent the invitation itself.
      assert sent_attendee_lines() == [
               @attendee_ada,
               @attendee_bob,
               "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE:mailto:cleo@example.com"
             ]
    end
  end

  describe "rescheduling one occurrence of a synced CalDAV series" do
    # The occurrence the sync expanded out of the series below: it carries the
    # master's RRULE, and its href is the series' resource, because on CalDAV
    # there is only ever the one document.
    @series_ical """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    BEGIN:VEVENT\r
    UID:weekly-standup\r
    DTSTAMP:20260901T090000Z\r
    DTSTART:20260908T090000Z\r
    DTEND:20260908T091500Z\r
    RRULE:FREQ=WEEKLY;BYDAY=TU\r
    SUMMARY:Weekly standup\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    setup %{integration: integration} do
      occurrence =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "weekly-standup_20260915T090000",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/weekly-standup.ics",
          summary: "Weekly standup",
          start_at: ~U[2026-09-15 09:00:00.000000Z],
          end_at: ~U[2026-09-15 09:15:00.000000Z],
          all_day: false,
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
          etag: "\"etag-1\"",
          raw_ical: @series_ical,
          sync_state: "synced"
        )

      %{occurrence: occurrence}
    end

    # No `expect`: under `verify_on_exit!` a PUT that reached the server would
    # fail the test as an unexpected call. That is the assertion — the patcher
    # would have rewritten the master's DTSTART and moved every Tuesday.
    test "is refused before anything is written", %{user: user, occurrence: occurrence} do
      assert {:error, %{reason: :recurring_event, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{
                 start_at: ~U[2026-09-15 11:00:00.000000Z],
                 end_at: ~U[2026-09-15 11:15:00.000000Z]
               })
    end

    test "leaves the cached occurrence at the time it was synced at", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      assert {:error, _failure} =
               CalendarGrid.update_event(user.id, occurrence, %{
                 start_at: ~U[2026-09-15 11:00:00.000000Z],
                 end_at: ~U[2026-09-15 11:15:00.000000Z]
               })

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)
      assert row.start_at == ~U[2026-09-15 09:00:00.000000Z]
      assert row.end_at == ~U[2026-09-15 09:15:00.000000Z]
    end

    test "is refused for an optimistic copy whose own timing already moved", %{
      user: user,
      occurrence: occurrence
    } do
      # What the grid assigns while the drag is still in flight. The guard reads
      # the cached row rather than this, so a caller cannot edit its way past it.
      optimistic = %{occurrence | start_at: ~U[2026-09-15 11:00:00.000000Z]}

      assert {:error, %{reason: :recurring_event}} =
               CalendarGrid.update_event(user.id, optimistic, %{
                 start_at: ~U[2026-09-15 11:00:00.000000Z],
                 end_at: ~U[2026-09-15 11:15:00.000000Z]
               })
    end

    # The payload is always the complete event, so a rename carries the
    # occurrence's own DTSTART too: the patcher would write 15 September onto
    # a series that starts on the 8th, dropping the first occurrence. No edit
    # of an occurrence stays inside it, which is why the refusal is not
    # limited to a reschedule.
    test "a rename is refused for the same reason", %{user: user, occurrence: occurrence} do
      assert {:error, %{reason: :recurring_event, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Daily standup"})
    end

    test "the one-off event on the same calendar is still editable", %{
      user: user,
      event: event
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn _url, body, _headers, _opts ->
        send(test_pid, {:put, body})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, event, %{
                 start_at: ~U[2026-09-10 11:00:00.000000Z],
                 end_at: ~U[2026-09-10 12:00:00.000000Z]
               })

      assert_received {:put, body}
      assert "DTSTART:20260910T110000Z" in LineFolder.unfold_lines(body)
    end
  end
end
