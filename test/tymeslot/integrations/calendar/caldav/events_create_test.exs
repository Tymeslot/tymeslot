defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsCreateTest do
  @moduledoc """
  What a CalDAV create answers with.

  Split from `EventsTest`, which covers reads, the ETag-conditional update and
  retries; this module covers only the PUT that writes a new event and the
  identity it reports back.
  """
  use Tymeslot.HttpTransportCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.Events
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/calendars/user/personal/"],
    verify_ssl: true,
    provider: :caldav
  }

  describe "CaldavCommon.create_event/2 — which calendar the write lands on" do
    @booking_client %{
      base_url: "https://caldav.example.com",
      username: "user",
      password: "pass",
      calendar_paths: ["/calendars/user/bookings/"],
      writable_calendar_paths: [
        "/calendars/user/bookings/",
        "/calendars/user/team/"
      ],
      verify_ssl: true,
      provider: :caldav
    }

    defp event_data do
      %{
        uid: "chosen-calendar-uid",
        summary: "Design review",
        start_time: ~U[2026-05-01 10:00:00Z],
        end_time: ~U[2026-05-01 11:00:00Z]
      }
    end

    # The booking flow chooses no calendar, so the client's own collection is
    # still where a booking lands.
    test "writes to the client's own collection when the payload names none" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.request_path == "/calendars/user/bookings/chosen-calendar-uid.ics"
        Conn.send_resp(conn, 201, "")
      end)

      assert {:ok, %CreatedEvent{calendar_id: "/calendars/user/bookings/"}} =
               CaldavCommon.create_event(@booking_client, event_data())
    end

    # `event_data[:calendar_id]` was never read on this path, so an event
    # created on any other collection silently went to the booking one.
    test "writes to the calendar the payload asks for" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.request_path == "/calendars/user/team/chosen-calendar-uid.ics"
        Conn.send_resp(conn, 201, "")
      end)

      assert {:ok, %CreatedEvent{calendar_id: "/calendars/user/team/"}} =
               CaldavCommon.create_event(
                 @booking_client,
                 Map.put(event_data(), :calendar_id, "/calendars/user/team/")
               )
    end

    # `event_data` is caller-supplied; a path taken from it unchecked is a URL
    # taken from a payload.
    test "ignores a calendar the integration does not list as writable" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.request_path == "/calendars/user/bookings/chosen-calendar-uid.ics"
        Conn.send_resp(conn, 201, "")
      end)

      assert {:ok, %CreatedEvent{calendar_id: "/calendars/user/bookings/"}} =
               CaldavCommon.create_event(
                 @booking_client,
                 Map.put(event_data(), :calendar_id, "/calendars/someone-else/private/")
               )
    end
  end

  describe "create_calendar_event/4" do
    test "sends PUT to a server-root-relative URL and returns the UID" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        assert String.starts_with?(conn.request_path, "/calendars/user/personal/")

        Conn.send_resp(conn, 201, "")
      end)

      event_data = %{
        summary: "Team meeting",
        start_time: ~U[2026-03-01 10:00:00Z],
        end_time: ~U[2026-03-01 11:00:00Z]
      }

      assert {:ok, %CreatedEvent{uid: uid, provider_event_id: href}} =
               Events.create_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 event_data,
                 skip_breaker: true
               )

      # Server-generated UID: 16 random bytes in lowercase hex, plus the domain.
      assert uid =~ ~r/\A[0-9a-f]{32}@tymeslot\.com\z/
      assert href == "/calendars/user/personal/#{uid}.ics"
    end

    test "sends PUT to server-root path when base_url contains a CalDAV path — no path doubling" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        assert conn.method == "PUT"
        assert String.starts_with?(conn.request_path, "/dav/user%40example.com/Calendar/")
        refute String.contains?(conn.request_path, "/dav/user@example.com/dav/")

        Conn.send_resp(conn, 201, "")
      end)

      client = %{
        base_url: "https://caldav.example.com/dav/user@example.com",
        username: "user@example.com",
        password: "pass",
        calendar_paths: ["/dav/user%40example.com/Calendar/"],
        verify_ssl: true,
        provider: :zimbra
      }

      event_data = %{
        summary: "Test",
        start_time: ~U[2026-02-24 10:00:00Z],
        end_time: ~U[2026-02-24 11:00:00Z]
      }

      assert {:ok, %CreatedEvent{}} =
               Events.create_calendar_event(
                 client,
                 "/dav/user%40example.com/Calendar/",
                 event_data,
                 skip_breaker: true
               )
    end

    test "answers with the ETag the server assigned, quotes stripped as sync stores them" do
      ReqTest.stub(:tymeslot_http, fn conn ->
        conn
        |> Conn.put_resp_header("etag", ~s("abc123"))
        |> Conn.send_resp(201, "")
      end)

      assert {:ok, %CreatedEvent{etag: "abc123"}} =
               Events.create_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 event_payload(),
                 skip_breaker: true
               )
    end

    # RFC 4791 only says a server SHOULD answer a PUT with an ETag, and a server
    # that rewrote the submitted document must not. The create still succeeded.
    test "answers without an ETag when the server did not send one" do
      ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 201, "") end)

      assert {:ok, %CreatedEvent{etag: nil, uid: uid}} =
               Events.create_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 event_payload(),
                 skip_breaker: true
               )

      assert uid =~ ~r/\A[0-9a-f]{32}@tymeslot\.com\z/
    end

    test "answers with the href the resource was written to, not the whole URL" do
      ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 201, "") end)

      assert {:ok, %CreatedEvent{provider_event_id: href}} =
               Events.create_calendar_event(
                 @caldav_client,
                 "/calendars/user/personal/",
                 Map.put(event_payload(), :uid, "fixed-uid"),
                 skip_breaker: true
               )

      # Sync spells a CalDAV provider_event_id as a server-root-relative path,
      # and `Selection` tells a CalDAV event from an OAuth one by that leading
      # slash, so an absolute URL here would be filed as another provider's id.
      assert href == "/calendars/user/personal/fixed-uid.ics"
    end

    defp event_payload do
      %{
        summary: "Team meeting",
        start_time: ~U[2026-03-01 10:00:00Z],
        end_time: ~U[2026-03-01 11:00:00Z]
      }
    end
  end
end
