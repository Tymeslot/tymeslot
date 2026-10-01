defmodule Tymeslot.Integrations.Calendar.CalDAV.BookingUpdatePatchTest do
  @moduledoc """
  A booking update on a CalDAV calendar patches the event the organiser's
  server holds instead of rebuilding it from Tymeslot's payload.

  The journey is a reschedule as the calendar worker carries it out: the
  meeting moves, `CalendarEventWorker` runs its `update`, and everything from
  there to the request body is real (`CalendarEventSync`, client resolution,
  the provider adapter, `CalDAV.Events`, the patcher). Only the HTTP boundary
  is stubbed. What the organiser added to the event in their own client,
  `CATEGORIES`, an `X-` property, a second `ATTENDEE` with their reply and
  their own alarm, has to reach the server again unchanged.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :integration

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.BookingDocument
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Workers.CalendarEventWorker

  @base_url "https://booking-patch.example.com"
  @calendar_path "/calendars/user/personal/"
  @event_uid "booking-patch-1@tymeslot.com"
  @href @calendar_path <> @event_uid <> ".ics"

  @moved_start ~U[2026-11-03 15:00:00Z]
  @moved_end ~U[2026-11-03 15:30:00Z]

  @second_attendee "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=OPT-PARTICIPANT;CN=Bob:mailto:bob@example.com"

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    # The suite points `:calendar_module` at a Mox double; this journey is
    # about what reaches the server, so the production implementation runs.
    with_config(:tymeslot, :calendar_module, Tymeslot.Integrations.Calendar.Operations)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: @base_url,
        calendar_paths: [@calendar_path],
        default_booking_calendar_id: @calendar_path
      )

    insert(:profile, user: user, primary_calendar_integration_id: integration.id)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        calendar_integration_id: integration.id,
        calendar_path: @calendar_path,
        calendar_uid: @event_uid,
        title: "Intro call",
        start_time: ~U[2026-11-02 09:00:00Z],
        end_time: ~U[2026-11-02 09:30:00Z],
        reminders: [%{"value" => 30, "unit" => "minutes"}]
      )

    %{user: user, integration: integration, meeting: meeting}
  end

  describe "a reschedule of a booking the organiser has touched" do
    test "keeps what their client added and moves the event", ctx do
      cache_document(ctx.integration, organiser_document(), "\"etag-1\"")
      serve(fn _method, _path -> {204, []} end)

      assert :ok = reschedule(ctx.meeting)

      assert [{"PUT", @href, ["\"etag-1\""], body}] = requests()
      lines = LineFolder.unfold_lines(body)

      assert "CATEGORIES:CLIENT-A" in lines
      assert "X-ORGANISER-NOTE:bring the slides" in lines
      assert @second_attendee in lines
      assert "DTSTART:20261103T150000Z" in lines
      assert "DTEND:20261103T153000Z" in lines
      refute "DTSTART:20261102T090000Z" in lines
    end

    # The booking payload always carries the meeting's reminders. They were
    # written when the booking was created and cannot change after it, so on
    # a patch they would only replace whatever alarm the organiser set.
    test "keeps the organiser's own alarm rather than writing the booking's reminders", ctx do
      cache_document(ctx.integration, organiser_document(), "\"etag-1\"")
      serve(fn _method, _path -> {204, []} end)

      assert :ok = reschedule(ctx.meeting)

      assert [{"PUT", @href, _if_match, body}] = requests()
      lines = LineFolder.unfold_lines(body)

      assert "TRIGGER:-PT2H" in lines
      refute "TRIGGER:-PT30M" in lines
      assert Enum.count(lines, &(&1 == "BEGIN:VALARM")) == 1
    end

    test "a stale cached ETag ends in a read and a patch of the server's copy", ctx do
      cache_document(ctx.integration, organiser_document(), "\"etag-1\"")

      server_copy =
        String.replace(organiser_document(), "CATEGORIES:CLIENT-A", "CATEGORIES:CLIENT-B")

      puts = :counters.new(1, [])

      serve(fn
        "PUT", _path ->
          :counters.add(puts, 1, 1)
          if :counters.get(puts, 1) == 1, do: {412, []}, else: {204, []}

        "GET", _path ->
          {200, [{"etag", "\"etag-2\""}], server_copy}
      end)

      assert :ok = reschedule(ctx.meeting)

      assert [
               {"PUT", @href, ["\"etag-1\""], _stale},
               {"GET", @href, [], _read},
               {"PUT", @href, ["\"etag-2\""], body}
             ] = requests()

      lines = LineFolder.unfold_lines(body)

      # The server's copy, not the cached one, and not a rebuild.
      assert "CATEGORIES:CLIENT-B" in lines
      refute "CATEGORIES:CLIENT-A" in lines
      assert @second_attendee in lines
      assert "DTSTART:20261103T150000Z" in lines
    end
  end

  describe "falling back to a rebuild" do
    test "a booking with no cached row is rebuilt from the payload, reminders included", ctx do
      serve(fn
        "HEAD", _path -> {200, [{"etag", "\"etag-9\""}]}
        "PUT", _path -> {204, []}
      end)

      assert :ok = reschedule(ctx.meeting)

      assert [{"HEAD", @href, [], _head}, {"PUT", @href, ["\"etag-9\""], body}] = requests()
      lines = LineFolder.unfold_lines(body)

      assert "PRODID:-//Tymeslot//CalDAV Client//EN" in lines
      assert "TRIGGER:-PT30M" in lines
      assert "DTSTART:20261103T150000Z" in lines
    end

    test "a cached row of another integration is never patched onto this event", ctx do
      other = insert(:calendar_integration, user: ctx.user, provider: "caldav")
      cache_document(other, organiser_document(), "\"etag-1\"")

      serve(fn
        "HEAD", _path -> {200, [{"etag", "\"etag-9\""}]}
        "PUT", _path -> {204, []}
      end)

      assert :ok = reschedule(ctx.meeting)

      assert [{"HEAD", @href, [], _head}, {"PUT", @href, ["\"etag-9\""], body}] = requests()
      refute body =~ "CATEGORIES:CLIENT-A"
    end

    # The organiser moved the event to another calendar after the last sync,
    # and Tymeslot has since written the booking back into its own calendar:
    # the cached href addresses nothing. The update must still land, on the
    # event the UID names, rather than end as a missing event.
    test "an event gone from its cached href is written where its UID puts it", ctx do
      moved_href = "/calendars/user/archive/" <> @event_uid <> ".ics"
      cache_document(ctx.integration, organiser_document(), "\"etag-1\"", moved_href)

      serve(fn
        _method, ^moved_href -> {404, []}
        "HEAD", @href -> {200, [{"etag", "\"etag-9\""}]}
        "PUT", @href -> {204, []}
      end)

      assert :ok = reschedule(ctx.meeting)

      assert {"PUT", @href, ["\"etag-9\""], body} = List.last(requests())
      assert "DTSTART:20261103T150000Z" in LineFolder.unfold_lines(body)
    end
  end

  describe "for_update/4 outside the CalDAV family" do
    for provider <- [:google, :outlook] do
      test "hands #{provider} the payload without the cached document", ctx do
        cache_document(ctx.integration, organiser_document(), "\"etag-1\"")
        payload = %{summary: "Intro call", reminders: []}

        assert :none =
                 BookingDocument.for_update(
                   %{provider_type: unquote(provider)},
                   @event_uid,
                   payload,
                   ctx.meeting
                 )

        # The same call for a CalDAV client does find the document, so the
        # answer above is the provider check and not a missed lookup.
        assert {:ok, %{raw_ical: raw_ical}} =
                 BookingDocument.for_update(
                   %{provider_type: :nextcloud},
                   @event_uid,
                   payload,
                   ctx.meeting
                 )

        assert raw_ical =~ "CATEGORIES:CLIENT-A"
      end
    end
  end

  # --- Helpers ---

  # The booking as Tymeslot created it, then edited in the organiser's
  # client: a category, a private note, a second attendee who accepted, and
  # an alarm of their own in place of the booking's 30-minute one.
  defp organiser_document do
    """
    BEGIN:VCALENDAR\r
    VERSION:2.0\r
    PRODID:-//Tymeslot//CalDAV Client//EN\r
    BEGIN:VEVENT\r
    UID:#{@event_uid}\r
    DTSTAMP:20261001T090000Z\r
    DTSTART:20261102T090000Z\r
    DTEND:20261102T093000Z\r
    SUMMARY:Intro call\r
    DESCRIPTION:Booked through Tymeslot\r
    LOCATION:\r
    STATUS:CONFIRMED\r
    TRANSP:OPAQUE\r
    CATEGORIES:CLIENT-A\r
    X-ORGANISER-NOTE:bring the slides\r
    ORGANIZER;SCHEDULE-AGENT=CLIENT;CN=Test Organizer:mailto:organiser@example.com\r
    ATTENDEE;SCHEDULE-AGENT=CLIENT;CN=Test Attendee:mailto:attendee@example.com\r
    #{@second_attendee}\r
    BEGIN:VALARM\r
    ACTION:DISPLAY\r
    DESCRIPTION:Reminder\r
    TRIGGER:-PT2H\r
    END:VALARM\r
    END:VEVENT\r
    END:VCALENDAR\r
    """
  end

  defp cache_document(integration, raw_ical, etag, href \\ @href) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: integration.provider,
      provider_calendar_id: @calendar_path,
      uid: @event_uid,
      provider_event_id: href,
      raw_ical: raw_ical,
      etag: etag
    )
  end

  # Answers each request with `respond.(method, path)`, which returns
  # `{status, headers}` or `{status, headers, body}`, and records it.
  defp serve(respond) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      if_match = Conn.get_req_header(conn, "if-match")
      send(test_pid, {:request, conn.method, conn.request_path, if_match, body})

      {status, headers, resp_body} =
        case respond.(conn.method, conn.request_path) do
          {status, headers} -> {status, headers, ""}
          {status, headers, resp_body} -> {status, headers, resp_body}
        end

      headers
      |> Enum.reduce(conn, fn {key, value}, acc -> Conn.put_resp_header(acc, key, value) end)
      |> Conn.resp(status, resp_body)
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:request, method, path, if_match, body} ->
        requests([{method, path, if_match, body} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp reschedule(meeting) do
    {:ok, _moved} =
      meeting
      |> Changeset.change(start_time: @moved_start, end_time: @moved_end)
      |> Repo.update()

    perform_job(CalendarEventWorker, %{"action" => "update", "meeting_id" => meeting.id})
  end
end
