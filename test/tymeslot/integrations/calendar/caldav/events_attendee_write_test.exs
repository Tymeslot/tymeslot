defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsAttendeeWriteTest do
  @moduledoc """
  What a booking's attendee looks like in the document that reaches the server.

  Issue #123: a CalDAV event Tymeslot wrote listed the organiser as its only
  participant, with whoever booked mentioned only in the description, so the
  organiser's calendar client had nobody to send an update to. These pin the
  property each kind of server is now sent, at the write path rather than at
  the serialiser, because the decision is the client's and only this path
  makes it.
  """
  use Tymeslot.HttpTransportCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.Events
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder

  @calendar_path "/calendars/user/personal/"
  @uid "booking-123"

  @booking %{
    uid: @uid,
    summary: "Intro call with Julian",
    description: "Attendee: Julian <julian@example.com>",
    start_time: ~U[2026-10-01 09:00:00Z],
    end_time: ~U[2026-10-01 10:00:00Z],
    organizer_email: "owner@example.com",
    organizer_name: "Owner",
    attendee_email: "julian@example.com",
    attendee_name: "Julian"
  }

  defp client(provider, base_url) do
    %Client{
      provider: provider,
      base_url: base_url,
      username: "user",
      password: "pass",
      calendar_paths: [@calendar_path]
    }
  end

  # The lines a calendar client reads: the document goes out folded, and an
  # ATTENDEE line is long enough that it always is.
  defp create_and_capture(client) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      send(test_pid, {:body, body})
      Conn.send_resp(conn, 201, "")
    end)

    assert {:ok, _created} =
             Events.create_calendar_event(client, @calendar_path, @booking, skip_breaker: true)

    assert_received {:body, body}
    LineFolder.unfold_lines(body)
  end

  describe "create_calendar_event/4" do
    test "writes the attendee as a real ATTENDEE on a server that honours SCHEDULE-AGENT" do
      lines = create_and_capture(client(:nextcloud, "https://cloud.example.com/remote.php/dav"))

      assert "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE;CN=Julian:mailto:julian@example.com" in lines

      refute Enum.any?(lines, &String.starts_with?(&1, "CONTACT"))
    end

    test "marks its own ATTENDEE block so a later edit can tell it from the organiser's" do
      lines = create_and_capture(client(:nextcloud, "https://cloud.example.com/remote.php/dav"))

      assert "X-TYMESLOT-ATTENDEES:1" in lines
    end

    test "falls back to CONTACT on Zimbra, which would invite the attendee itself" do
      lines = create_and_capture(client(:zimbra, "https://mail.example.com/dav/user@example.com"))

      assert "CONTACT:Julian <julian@example.com>" in lines
      refute Enum.any?(lines, &String.starts_with?(&1, "ATTENDEE"))
      refute "X-TYMESLOT-ATTENDEES:1" in lines
    end

    test "treats a Zimbra behind the generic CalDAV provider as Zimbra" do
      lines = create_and_capture(client(:caldav, "https://mail.example.com/dav/user@example.com"))

      assert "CONTACT:Julian <julian@example.com>" in lines
      refute Enum.any?(lines, &String.starts_with?(&1, "ATTENDEE"))
    end
  end
end
