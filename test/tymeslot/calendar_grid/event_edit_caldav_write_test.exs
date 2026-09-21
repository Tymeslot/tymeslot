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
end
