defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsPatchedUpdateTest do
  @moduledoc """
  What reaches the server when an event Tymeslot did not write is edited.

  Split from `EventsTest`, which covers the rebuild-from-payload write: this
  module covers the other writer, the one that takes the stored iCalendar
  document and rewrites only the properties the payload carries. The
  distinction is not cosmetic. Rebuilding a foreign event would replace its
  `ATTENDEE` block with Tymeslot's own single attendee, which for an event
  created in another client destroys every participant's invitation and
  recorded response.
  """
  use Tymeslot.HttpTransportCase, async: false
  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.Events
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder

  @caldav_client %Client{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/calendars/user/personal/"],
    verify_ssl: true,
    provider: :caldav
  }

  @calendar_path "/calendars/user/personal/"
  @uid "foreign-event-1"

  @stored_ical """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  PRODID:-//Mozilla.org/NONSGML Mozilla Calendar V1.1//EN\r
  BEGIN:VEVENT\r
  UID:foreign-event-1\r
  DTSTAMP:20260901T090000Z\r
  DTSTART:20260910T090000Z\r
  DTEND:20260910T100000Z\r
  SUMMARY:Sprint review\r
  CATEGORIES:WORK\r
  ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada:mailto:ada@example.com\r
  ATTENDEE;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:bob@example.com\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  # The payload the calendar grid sends for a rename: the whole event as the
  # cache models it, plus the stored document and the ETag it came with.
  defp rename_payload(extra \\ %{}) do
    Map.merge(
      %{
        summary: "Renamed",
        description: "",
        location: "",
        start_time: ~U[2026-09-10 09:00:00Z],
        end_time: ~U[2026-09-10 10:00:00Z],
        all_day: false,
        attendees: [%{"email" => "ada@example.com", "name" => "Ada"}],
        reminders: [],
        recurrence_rule: nil,
        recurrence_exceptions: [],
        colour: nil,
        raw_ical: @stored_ical,
        etag: "\"etag-1\""
      },
      extra
    )
  end

  defp update(payload, opts \\ [skip_breaker: true]) do
    Events.update_calendar_event(@caldav_client, @calendar_path, @uid, payload, opts)
  end

  # Content lines as a client reads them: the document goes out folded.
  defp sent_lines(body), do: LineFolder.unfold_lines(body)

  describe "update_calendar_event/5 with the stored document" do
    test "keeps the event's ATTENDEE lines and adds no CONTACT line" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:request, conn.method, body, Conn.get_req_header(conn, "if-match")})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok = update(rename_payload())

      assert_received {:request, "PUT", body, if_match}
      lines = sent_lines(body)

      assert "ATTENDEE;PARTSTAT=ACCEPTED;ROLE=REQ-PARTICIPANT;CN=Ada:mailto:ada@example.com" in lines
      assert "ATTENDEE;PARTSTAT=ACCEPTED;RSVP=TRUE:mailto:bob@example.com" in lines
      refute body =~ "CONTACT:"

      assert "SUMMARY:Renamed" in lines
      assert "CATEGORIES:WORK" in lines
      assert if_match == ["\"etag-1\""]

      # The cached ETag is the precondition, so nothing else is asked of the
      # server: no HEAD probe, no read.
      refute_received {:request, _method, _body, _if_match}
    end

    test "sends the payload's own properties, not the stored ones" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:body, body})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok =
               update(
                 rename_payload(%{
                   start_time: ~U[2026-09-11 14:00:00Z],
                   end_time: ~U[2026-09-11 15:00:00Z],
                   location: "Room 9"
                 })
               )

      assert_received {:body, body}
      lines = sent_lines(body)

      assert "DTSTART:20260911T140000Z" in lines
      assert "DTEND:20260911T150000Z" in lines
      assert "LOCATION:Room 9" in lines
      refute "DTSTART:20260910T090000Z" in lines
    end

    test "reads the server's copy first when the cached document has no ETag" do
      server_ical =
        String.replace(@stored_ical, "CATEGORIES:WORK", "CATEGORIES:WORK,ADDED-ON-THE-SERVER")

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Conn.put_resp_header("etag", "\"etag-live\"")
            |> Conn.send_resp(200, server_ical)

          "PUT" ->
            {:ok, body, conn} = Conn.read_body(conn)
            send(test_pid, {:put, body, Conn.get_req_header(conn, "if-match")})
            Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = update(rename_payload(%{etag: nil}))

      assert_received {:put, body, if_match}

      # Patched onto what the server has now, under the ETag that copy came
      # with — never onto a cached document nothing vouches for.
      assert "CATEGORIES:WORK,ADDED-ON-THE-SERVER" in sent_lines(body)
      assert "SUMMARY:Renamed" in sent_lines(body)
      assert if_match == ["\"etag-live\""]
    end

    test "re-reads and patches the server's copy when the precondition fails" do
      server_ical =
        String.replace(@stored_ical, "CATEGORIES:WORK", "CATEGORIES:WORK,CHANGED-MEANWHILE")

      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        case {conn.method, Conn.get_req_header(conn, "if-match")} do
          {"PUT", ["\"etag-1\""]} ->
            Conn.send_resp(conn, 412, "Precondition Failed")

          {"GET", _any} ->
            conn
            |> Conn.put_resp_header("etag", "\"etag-2\"")
            |> Conn.send_resp(200, server_ical)

          {"PUT", if_match} ->
            {:ok, body, conn} = Conn.read_body(conn)
            send(test_pid, {:retry, body, if_match})
            Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = update(rename_payload())

      assert_received {:retry, body, if_match}
      lines = sent_lines(body)

      # The organiser's rename lands on top of the server's change rather than
      # reverting it, and the retry is still conditional.
      assert "SUMMARY:Renamed" in lines
      assert "CATEGORIES:WORK,CHANGED-MEANWHILE" in lines
      assert if_match == ["\"etag-2\""]
    end

    test "a :keep_server caller lets the server's copy stand rather than re-reading" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:request, conn.method})
        Conn.send_resp(conn, 412, "Precondition Failed")
      end)

      assert :ok =
               update(rename_payload(), conflict_resolution: :keep_server, skip_breaker: true)

      assert_received {:request, "PUT"}
      refute_received {:request, _method}
    end

    test "surfaces the conflict when the re-read copy is rejected too" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.method do
          "GET" ->
            conn
            |> Conn.put_resp_header("etag", "\"etag-2\"")
            |> Conn.send_resp(200, @stored_ical)

          "PUT" ->
            Conn.send_resp(conn, 412, "Precondition Failed")
        end
      end)

      assert {:error, :precondition_failed} = update(rename_payload())
    end

    test "falls back to building the event when the server no longer has it" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        case conn.method do
          "GET" ->
            Conn.send_resp(conn, 404, "")

          "HEAD" ->
            Conn.send_resp(conn, 404, "")

          "PUT" ->
            {:ok, body, conn} = Conn.read_body(conn)
            send(test_pid, {:put, body})
            Conn.send_resp(conn, 204, "")
        end
      end)

      assert :ok = update(rename_payload(%{etag: nil}))

      assert_received {:put, body}
      assert "SUMMARY:Renamed" in sent_lines(body)
      assert "UID:foreign-event-1" in sent_lines(body)
    end

    test "builds the event when the cached document holds no VEVENT" do
      test_pid = self()

      ReqTest.stub(:tymeslot_http, fn conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:put, body})
        Conn.send_resp(conn, 204, "")
      end)

      assert :ok = update(rename_payload(%{raw_ical: "BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"}))

      assert_received {:put, body}
      lines = sent_lines(body)

      assert "BEGIN:VEVENT" in lines
      assert "SUMMARY:Renamed" in lines
    end
  end
end
