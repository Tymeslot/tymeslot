defmodule Tymeslot.Integrations.Calendar.CalDAV.EventsUrlResolutionTest do
  @moduledoc """
  Which URL a write to an existing event is sent to.

  Split from `EventsTest`, which covers the request protocol itself; this
  module covers only the choice of resource: the server-supplied href when the
  event has been synced, the calendar path and UID when it has not, and the
  joining rules that keep either one pointing at the event the user edited.
  """
  use Tymeslot.HttpTransportCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.Events

  @caldav_client %{
    base_url: "https://caldav.example.com",
    username: "user",
    password: "pass",
    calendar_paths: ["/calendars/user/personal/"],
    verify_ssl: true,
    provider: :caldav
  }

  describe "event URL resolution" do
    # Regression: every write that reused a synced event's cached href glued it
    # onto the *whole* base_url. A Nextcloud base_url is normalised to the DAV
    # root ("…/remote.php/dav") and the href the server returns starts with
    # that same root, so the path doubled:
    # /remote.php/dav/remote.php/dav/calendars/… The HEAD 404ed, the
    # conditional PUT 412ed, and the user saw "changes reverted" on every
    # inline edit of a synced event.
    @dav_root_client %{
      @caldav_client
      | base_url: "https://cloud.example.com/remote.php/dav",
        calendar_paths: ["/remote.php/dav/calendars/user/personal/"]
    }

    @event_data %{
      summary: "Edited inline",
      start_time: ~U[2026-02-24 10:00:00Z],
      end_time: ~U[2026-02-24 11:00:00Z]
    }

    defp record_path_stub(test_pid) do
      ReqTest.stub(:tymeslot_http, fn conn ->
        send(test_pid, {:request, conn.method, conn.host, conn.request_path})
        Conn.send_resp(conn, 204, "")
      end)
    end

    test "PUTs to the cached href without doubling the base path" do
      record_path_stub(self())

      assert :ok =
               Events.update_calendar_event(
                 @dav_root_client,
                 "/remote.php/dav/calendars/user/personal/",
                 "synced-uid",
                 Map.put(
                   @event_data,
                   :provider_event_id,
                   "/remote.php/dav/calendars/user/personal/synced-uid.ics"
                 ),
                 etag: "\"cached-etag\"",
                 skip_breaker: true
               )

      assert_receive {:request, "PUT", "cloud.example.com",
                      "/remote.php/dav/calendars/user/personal/synced-uid.ics"}
    end

    test "PUTs to the cached href on a subfolder install" do
      record_path_stub(self())

      client = %{
        @dav_root_client
        | base_url: "https://example.com/nextcloud/remote.php/dav"
      }

      assert :ok =
               Events.update_calendar_event(
                 client,
                 "/nextcloud/remote.php/dav/calendars/user/personal/",
                 "synced-uid",
                 Map.put(
                   @event_data,
                   :provider_event_id,
                   "/nextcloud/remote.php/dav/calendars/user/personal/synced-uid.ics"
                 ),
                 etag: "\"cached-etag\"",
                 skip_breaker: true
               )

      assert_receive {:request, "PUT", "example.com",
                      "/nextcloud/remote.php/dav/calendars/user/personal/synced-uid.ics"}
    end

    test "PUTs to the cached href when base_url carries a trailing slash" do
      record_path_stub(self())

      client = %{@dav_root_client | base_url: "https://cloud.example.com/remote.php/dav/"}

      assert :ok =
               Events.update_calendar_event(
                 client,
                 "/remote.php/dav/calendars/user/personal/",
                 "synced-uid",
                 Map.put(
                   @event_data,
                   :provider_event_id,
                   "/remote.php/dav/calendars/user/personal/synced-uid.ics"
                 ),
                 etag: "\"cached-etag\"",
                 skip_breaker: true
               )

      assert_receive {:request, "PUT", "cloud.example.com",
                      "/remote.php/dav/calendars/user/personal/synced-uid.ics"}
    end

    # Some servers (iCloud) hand back an absolute href on a per-user partition
    # host. The write must keep its path but stay pinned to the already
    # SSRF-validated base origin rather than following the server anywhere it
    # names.
    test "pins an absolute href to the validated base origin" do
      record_path_stub(self())

      assert :ok =
               Events.update_calendar_event(
                 @dav_root_client,
                 "/remote.php/dav/calendars/user/personal/",
                 "synced-uid",
                 Map.put(
                   @event_data,
                   :provider_event_id,
                   "https://p110-caldav.example.net/remote.php/dav/calendars/user/personal/synced-uid.ics"
                 ),
                 etag: "\"cached-etag\"",
                 skip_breaker: true
               )

      assert_receive {:request, "PUT", "cloud.example.com",
                      "/remote.php/dav/calendars/user/personal/synced-uid.ics"}
    end

    test "DELETEs the cached href without doubling the base path" do
      record_path_stub(self())

      assert :ok =
               Events.delete_calendar_event(
                 @dav_root_client,
                 "/remote.php/dav/calendars/user/personal/",
                 "synced-uid",
                 skip_breaker: true,
                 provider_event_id: "/remote.php/dav/calendars/user/personal/synced-uid.ics"
               )

      assert_receive {:request, "DELETE", "cloud.example.com",
                      "/remote.php/dav/calendars/user/personal/synced-uid.ics"}
    end

    test "writes a colour patch to the cached href without doubling the base path" do
      record_path_stub(self())

      raw_ical =
        "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:synced-uid\nEND:VEVENT\nEND:VCALENDAR\n"

      assert :ok =
               Events.update_event_colour(
                 @dav_root_client,
                 "/remote.php/dav/calendars/user/personal/",
                 "synced-uid",
                 "blueberry",
                 raw_ical: raw_ical,
                 etag: "\"cached-etag\"",
                 provider_event_id: "/remote.php/dav/calendars/user/personal/synced-uid.ics",
                 skip_breaker: true
               )

      assert_receive {:request, "PUT", "cloud.example.com",
                      "/remote.php/dav/calendars/user/personal/synced-uid.ics"}
    end

    test "falls back to calendar_path + uid when no href is cached" do
      record_path_stub(self())

      assert :ok =
               Events.update_calendar_event(
                 @dav_root_client,
                 "/remote.php/dav/calendars/user/personal/",
                 "unsynced-uid",
                 @event_data,
                 etag: "\"cached-etag\"",
                 skip_breaker: true
               )

      assert_receive {:request, "PUT", "cloud.example.com",
                      "/remote.php/dav/calendars/user/personal/unsynced-uid.ics"}
    end
  end
end
