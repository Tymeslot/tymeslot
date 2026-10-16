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
  alias Tymeslot.CalDAVTestHelpers
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
  #
  # An Open-Xchange write first asks the account for its own addresses
  # (`CalDAV.Scheduling`), which `addresses` answers; `:unreadable` fails
  # that lookup.
  defp create_and_capture(client, addresses \\ ["owner@example.com"]) do
    stub_server(addresses)

    assert {:ok, _created} =
             Events.create_calendar_event(client, @calendar_path, @booking, skip_breaker: true)

    assert_received {:body, body}
    LineFolder.unfold_lines(body)
  end

  defp stub_server(addresses) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn
      %{method: "PROPFIND"} = conn when addresses == :unreadable ->
        Conn.send_resp(conn, 500, "")

      %{method: "PROPFIND"} = conn ->
        CalDAVTestHelpers.answer_address_lookup(conn, addresses)

      conn ->
        {:ok, body, conn} = Conn.read_body(conn)
        send(test_pid, {:body, body})
        Conn.send_resp(conn, 201, "")
    end)
  end

  defp attendee_lines(lines), do: Enum.filter(lines, &String.starts_with?(&1, "ATTENDEE"))

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

    # Issue #151: Open-Xchange adds the calendar's owner to any event that does
    # not already list them, under the account's primary address, so an
    # organiser writing from an alias saw their login address join the meeting.
    test "lists the organiser as the accepted chair on mailbox.org" do
      lines = create_and_capture(client(:mailbox_org, "https://dav.mailbox.org"))

      assert "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=CHAIR;PARTSTAT=ACCEPTED;RSVP=FALSE;CN=Owner:mailto:owner@example.com" in lines

      assert "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE;CN=Julian:mailto:julian@example.com" in lines

      assert "X-TYMESLOT-ATTENDEES:1" in lines
    end

    test "lists the organiser on an Open-Xchange server under another domain" do
      client = %{
        client(:caldav, "https://dav.example-hosting.de/caldav/")
        | calendar_paths: ["/caldav/Y2FsOi8vMC8zMg/"]
      }

      lines = create_and_capture(client)

      assert Enum.any?(lines, &(&1 =~ ~r/^ATTENDEE;.*ROLE=CHAIR.*:mailto:owner@example\.com$/))
    end

    # The reporter's case: an organiser on a custom domain the account does
    # not list as its own. The server adds its owner whatever the event says,
    # so the owner line is written under the address it would have added.
    test "lists the account's own address as the chair for an organiser the account does not own" do
      lines =
        create_and_capture(
          client(:mailbox_org, "https://dav.mailbox.org"),
          ["login@mailbox.org", "alias@mailbox.org"]
        )

      assert attendee_lines(lines) == [
               "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=CHAIR;PARTSTAT=ACCEPTED;RSVP=FALSE;CN=Owner:mailto:login@mailbox.org",
               "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=FALSE;CN=Julian:mailto:julian@example.com"
             ]

      assert "ORGANIZER;SCHEDULE-AGENT=CLIENT;CN=Owner:mailto:owner@example.com" in lines
    end

    test "lists an organiser writing from an alias the account owns under that alias" do
      lines =
        create_and_capture(
          client(:mailbox_org, "https://dav.mailbox.org"),
          ["login@mailbox.org", "owner@example.com"]
        )

      assert hd(attendee_lines(lines)) ==
               "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=CHAIR;PARTSTAT=ACCEPTED;RSVP=FALSE;CN=Owner:mailto:owner@example.com"

      refute Enum.any?(lines, &(&1 =~ "login@mailbox.org"))
    end

    test "lists the organiser when the account's addresses cannot be read" do
      lines = create_and_capture(client(:mailbox_org, "https://dav.mailbox.org"), :unreadable)

      assert hd(attendee_lines(lines)) ==
               "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=CHAIR;PARTSTAT=ACCEPTED;RSVP=FALSE;CN=Owner:mailto:owner@example.com"
    end

    test "writes an organiser who booked their own slot once, as the chair" do
      stub_server(["owner@example.com"])

      booking = %{@booking | attendee_email: "Owner@example.com", attendee_name: "Owner"}

      assert {:ok, _created} =
               Events.create_calendar_event(
                 client(:mailbox_org, "https://dav.mailbox.org"),
                 @calendar_path,
                 booking,
                 skip_breaker: true
               )

      assert_received {:body, body}

      assert body
             |> LineFolder.unfold_lines()
             |> Enum.filter(&String.starts_with?(&1, "ATTENDEE")) ==
               [
                 "ATTENDEE;SCHEDULE-AGENT=CLIENT;ROLE=CHAIR;PARTSTAT=ACCEPTED;RSVP=FALSE;CN=Owner:mailto:owner@example.com"
               ]
    end

    test "does not list the organiser on a server that adds nobody" do
      lines = create_and_capture(client(:nextcloud, "https://cloud.example.com/remote.php/dav"))

      refute Enum.any?(lines, &(&1 =~ ~r/^ATTENDEE;.*mailto:owner@example\.com$/))
    end
  end
end
