defmodule Tymeslot.Integrations.Calendar.CalDAV.ServerDetectorTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.ServerDetector

  describe "detect_by_hostname/1" do
    test "detects Radicale from hostname" do
      assert ServerDetector.detect_by_hostname("https://radicale.example.com") == :radicale
      assert ServerDetector.detect_by_hostname("https://my-radicale-server.com") == :radicale
    end

    test "detects Nextcloud from hostname" do
      assert ServerDetector.detect_by_hostname("https://nextcloud.example.com") == :nextcloud
    end

    test "detects ownCloud from hostname" do
      assert ServerDetector.detect_by_hostname("https://owncloud.example.com") == :owncloud
    end

    test "detects Baikal from hostname" do
      assert ServerDetector.detect_by_hostname("https://baikal.example.com") == :baikal
    end

    test "detects SabreDAV from hostname" do
      assert ServerDetector.detect_by_hostname("https://sabredav.example.com") == :sabredav
    end

    test "detects Zimbra from hostname" do
      assert ServerDetector.detect_by_hostname("https://zimbra.example.com") == :zimbra
    end

    test "returns nil for unknown hostnames" do
      assert ServerDetector.detect_by_hostname("https://calendar.example.com") == nil
      assert ServerDetector.detect_by_hostname("https://dav.example.com") == nil
    end
  end

  describe "detect_by_path/2" do
    test "detects Radicale from exact port 5232 only" do
      assert ServerDetector.detect_by_path(
               "https://cal.example.com:5232",
               "https://cal.example.com:5232"
             ) ==
               :radicale

      # Should NOT match ports containing 5232 as substring
      assert ServerDetector.detect_by_path(
               "https://cal.example.com:15232",
               "https://cal.example.com:15232"
             ) ==
               nil

      assert ServerDetector.detect_by_path(
               "https://cal.example.com:52320",
               "https://cal.example.com:52320"
             ) ==
               nil
    end

    test "detects Nextcloud from /remote.php/webdav" do
      assert ServerDetector.detect_by_path(
               "https://cloud.example.com/remote.php/webdav",
               "https://cloud.example.com/remote.php/webdav"
             ) == :nextcloud
    end

    test "detects Nextcloud from /remote.php/dav (modern shared path)" do
      assert ServerDetector.detect_by_path(
               "https://cloud.example.com/remote.php/dav",
               "https://cloud.example.com/remote.php/dav"
             ) == :nextcloud
    end

    test "detects ownCloud from /remote.php/caldav" do
      assert ServerDetector.detect_by_path(
               "https://cloud.example.com/remote.php/caldav",
               "https://cloud.example.com/remote.php/caldav"
             ) == :owncloud
    end

    test "detects Baikal from /dav.php" do
      assert ServerDetector.detect_by_path(
               "https://cal.example.com/dav.php",
               "https://cal.example.com/dav.php"
             ) == :baikal
    end

    test "detects Baikal legacy from /cal.php" do
      assert ServerDetector.detect_by_path(
               "https://cal.example.com/cal.php",
               "https://cal.example.com/cal.php"
             ) == :baikal_legacy
    end

    test "detects SabreDAV from /server.php" do
      assert ServerDetector.detect_by_path(
               "https://dav.example.com/server.php",
               "https://dav.example.com/server.php"
             ) == :sabredav
    end

    test "detects Zimbra from /principals/users/" do
      assert ServerDetector.detect_by_path(
               "https://mail.example.com/principals/users/",
               "https://mail.example.com/principals/users/"
             ) == :zimbra
    end

    test "detects Zimbra from /home/ legacy pattern" do
      assert ServerDetector.detect_by_path(
               "https://mail.example.com/home/user@example.com/calendar.ics",
               "https://mail.example.com/home/user@example.com/calendar.ics"
             ) == :zimbra

      # Should NOT detect owncloud with /home/ in URL
      assert ServerDetector.detect_by_path(
               "https://owncloud.example.com/home/",
               "https://owncloud.example.com/home/"
             ) == nil
    end

    test "detects Zimbra from /dav/ with exclusions" do
      # Should detect as Zimbra
      assert ServerDetector.detect_by_path(
               "https://mail.example.com/dav/user@domain/",
               "https://mail.example.com/dav/user@domain/"
             ) == :zimbra

      # Should detect Zimbra even with .php in hostname
      assert ServerDetector.detect_by_path(
               "https://mail.php-servers.com/dav/user/",
               "https://mail.php-servers.com/dav/user/"
             ) == :zimbra

      # Should detect Zimbra even with .php in username
      assert ServerDetector.detect_by_path(
               "https://mail.example.com/dav/user.php@example.com/",
               "https://mail.example.com/dav/user.php@example.com/"
             ) == :zimbra

      # Should NOT detect as Zimbra (Nextcloud pattern)
      assert ServerDetector.detect_by_path(
               "https://cloud.example.com/remote.php/dav",
               "https://cloud.example.com/remote.php/dav"
             ) == :nextcloud

      # Should NOT detect as Zimbra (Baikal pattern)
      assert ServerDetector.detect_by_path(
               "https://cal.example.com/dav.php",
               "https://cal.example.com/dav.php"
             ) == :baikal
    end

    test "returns nil for unknown paths" do
      assert ServerDetector.detect_by_path(
               "https://calendar.example.com/calendars",
               "https://calendar.example.com/calendars"
             ) == nil
    end
  end

  describe "detect_from_url/1" do
    test "detects Radicale from hostname containing 'radicale'" do
      assert ServerDetector.detect_from_url("https://radicale.example.com") == :radicale
      assert ServerDetector.detect_from_url("https://my-radicale-server.com") == :radicale
      assert ServerDetector.detect_from_url("https://RADICALE.example.com") == :radicale
    end

    test "detects Radicale from port 5232" do
      assert ServerDetector.detect_from_url("https://cal.example.com:5232") == :radicale
      assert ServerDetector.detect_from_url("http://localhost:5232") == :radicale
    end

    test "detects Nextcloud from hostname containing 'nextcloud'" do
      assert ServerDetector.detect_from_url("https://nextcloud.example.com") == :nextcloud
      assert ServerDetector.detect_from_url("https://my-nextcloud.com") == :nextcloud
      assert ServerDetector.detect_from_url("https://NEXTCLOUD.example.com") == :nextcloud
    end

    test "detects Nextcloud from remote.php/dav path" do
      assert ServerDetector.detect_from_url("https://cloud.example.com/remote.php/dav") ==
               :nextcloud

      assert ServerDetector.detect_from_url("https://example.com/remote.php/webdav") ==
               :nextcloud
    end

    test "detects ownCloud from hostname" do
      assert ServerDetector.detect_from_url("https://owncloud.example.com") == :owncloud
      assert ServerDetector.detect_from_url("https://my-owncloud.com") == :owncloud
      assert ServerDetector.detect_from_url("https://OWNCLOUD.example.com") == :owncloud
    end

    test "detects ownCloud from remote.php/caldav path" do
      assert ServerDetector.detect_from_url("https://cloud.example.com/remote.php/caldav") ==
               :owncloud

      assert ServerDetector.detect_from_url("https://example.com/remote.php/caldav/calendars") ==
               :owncloud
    end

    test "detects Baikal from hostname containing 'baikal'" do
      assert ServerDetector.detect_from_url("https://baikal.example.com") == :baikal
      assert ServerDetector.detect_from_url("https://my-baikal.com") == :baikal
    end

    test "detects Baikal from dav.php path (modern)" do
      assert ServerDetector.detect_from_url("https://example.com/dav.php") == :baikal

      assert ServerDetector.detect_from_url("https://example.com/dav.php/calendars/username") ==
               :baikal
    end

    test "detects Baikal legacy from cal.php path" do
      assert ServerDetector.detect_from_url("https://example.com/cal.php") == :baikal_legacy

      assert ServerDetector.detect_from_url("https://example.com/cal.php/calendars") ==
               :baikal_legacy
    end

    test "detects SabreDAV from hostname containing 'sabre'" do
      assert ServerDetector.detect_from_url("https://sabredav.example.com") == :sabredav
      assert ServerDetector.detect_from_url("https://sabre.example.com") == :sabredav
    end

    test "detects SabreDAV from server.php path" do
      assert ServerDetector.detect_from_url("https://example.com/server.php") == :sabredav
    end

    test "detects Zimbra from hostname containing 'zimbra'" do
      assert ServerDetector.detect_from_url("https://zimbra.example.com") == :zimbra
      assert ServerDetector.detect_from_url("https://mail.zimbra.com") == :zimbra
      assert ServerDetector.detect_from_url("https://ZIMBRA.example.com") == :zimbra
    end

    test "detects Zimbra from principals/users path" do
      assert ServerDetector.detect_from_url("https://mail.example.com/principals/users/") ==
               :zimbra

      assert ServerDetector.detect_from_url(
               "https://mail.example.com/principals/users/user@example.com"
             ) == :zimbra
    end

    test "detects Zimbra from /dav/ path (when not conflicting with other servers)" do
      assert ServerDetector.detect_from_url("https://mail.example.com/dav/user@example.com") ==
               :zimbra

      assert ServerDetector.detect_from_url("https://mail.example.com/dav/user/Calendar/") ==
               :zimbra
    end

    test "detects Zimbra from /home/ legacy path" do
      assert ServerDetector.detect_from_url(
               "https://mail.example.com/home/user@example.com/calendar.ics"
             ) == :zimbra

      assert ServerDetector.detect_from_url("https://mail.example.com/home/user/") == :zimbra
    end

    test "does not detect Zimbra for /dav/ path that belongs to other servers" do
      # Nextcloud uses /remote.php/dav
      assert ServerDetector.detect_from_url("https://cloud.example.com/remote.php/dav") ==
               :nextcloud

      # Baikal uses /dav.php
      assert ServerDetector.detect_from_url("https://cal.example.com/dav.php") == :baikal
    end

    test "returns :generic for unknown CalDAV servers" do
      assert ServerDetector.detect_from_url("https://caldav.example.com") == :generic
      assert ServerDetector.detect_from_url("https://calendar.example.com") == :generic
      assert ServerDetector.detect_from_url("https://dav.example.com/calendars") == :generic
    end

    test "handles case-insensitive path detection" do
      # PHP paths should be detected regardless of case
      assert ServerDetector.detect_from_url("https://cloud.example.com/REMOTE.PHP/dav") ==
               :nextcloud

      assert ServerDetector.detect_from_url("https://cloud.example.com/Remote.Php/Dav") ==
               :nextcloud

      assert ServerDetector.detect_from_url("https://cal.example.com/DAV.PHP") == :baikal

      assert ServerDetector.detect_from_url("https://cal.example.com/CAL.PHP") ==
               :baikal_legacy
    end

    test "handles port edge cases correctly" do
      # Exact port 5232 should be detected
      assert ServerDetector.detect_from_url("https://cal.example.com:5232") == :radicale

      # Ports containing 5232 as substring should NOT be detected as Radicale
      assert ServerDetector.detect_from_url("https://cal.example.com:15232") == :generic
      assert ServerDetector.detect_from_url("https://cal.example.com:52320") == :generic
      assert ServerDetector.detect_from_url("https://cal.example.com:25232") == :generic
    end

    test "detects Zimbra with .php in hostname or username" do
      # Should still detect Zimbra even with .php in other parts of URL
      assert ServerDetector.detect_from_url("https://mail.php-servers.com/dav/user/") == :zimbra

      assert ServerDetector.detect_from_url("https://mail.example.com/dav/user.php@example.com/") ==
               :zimbra
    end
  end

  describe "detect_from_headers/1" do
    test "detects Radicale from Server header" do
      headers = %{"server" => ["radicale/3.1.8"]}
      assert ServerDetector.detect_from_headers(headers) == :radicale
    end

    test "detects Nextcloud from Server header" do
      headers = %{"server" => ["Apache/2.4.41 (Ubuntu) Nextcloud"]}
      assert ServerDetector.detect_from_headers(headers) == :nextcloud
    end

    test "detects Nextcloud from X-Powered-By header" do
      headers = %{"x-powered-by" => ["Nextcloud"]}
      assert ServerDetector.detect_from_headers(headers) == :nextcloud
    end

    test "detects ownCloud from Server header" do
      headers = %{"server" => ["Apache ownCloud"]}
      assert ServerDetector.detect_from_headers(headers) == :owncloud
    end

    test "detects Baikal from Server header" do
      headers = %{"server" => ["Baikal/0.9.3"]}
      assert ServerDetector.detect_from_headers(headers) == :baikal
    end

    test "detects SabreDAV from Server header" do
      headers = %{"server" => ["SabreDAV/4.3.1"]}
      assert ServerDetector.detect_from_headers(headers) == :sabredav
    end

    test "detects Zimbra from Server header" do
      headers = %{"server" => ["Zimbra/8.8.15"]}
      assert ServerDetector.detect_from_headers(headers) == :zimbra
    end

    test "returns generic for calendar-access in DAV header" do
      headers = %{"dav" => ["1, 2, calendar-access"]}
      assert ServerDetector.detect_from_headers(headers) == :generic
    end

    test "returns nil for unrecognized headers" do
      headers = %{"server" => ["nginx/1.18.0"]}
      assert ServerDetector.detect_from_headers(headers) == nil
    end

    test "handles case-insensitive header values" do
      # Req normalises header names to lowercase; values may still be mixed-case.
      assert ServerDetector.detect_from_headers(%{"server" => ["Radicale/3.1.8"]}) == :radicale
      assert ServerDetector.detect_from_headers(%{"x-powered-by" => ["NextCloud"]}) == :nextcloud
    end
  end

  describe "get_server_profile/1" do
    test "returns Radicale profile with correct paths" do
      profile = ServerDetector.get_server_profile(:radicale)

      assert profile.type == :radicale
      assert profile.discovery_path == "/{username}/"
      assert profile.calendar_path_pattern == "/{username}/{calendar}/"
      assert profile.event_path_pattern == "/{username}/{calendar}/{uid}.ics"
      refute profile.supports_oauth
      assert profile.supports_calendar_color == true
      assert profile.requires_calendar_suffix == true
    end

    test "returns Nextcloud profile with correct paths" do
      profile = ServerDetector.get_server_profile(:nextcloud)

      assert profile.type == :nextcloud
      assert profile.discovery_path == "/remote.php/dav/calendars/{username}/"

      assert profile.calendar_path_pattern ==
               "/remote.php/dav/calendars/{username}/{calendar}/"

      assert profile.event_path_pattern ==
               "/remote.php/dav/calendars/{username}/{calendar}/{uid}.ics"

      assert profile.supports_oauth == true
      assert profile.supports_calendar_color == true
      refute profile.requires_calendar_suffix
    end

    test "returns ownCloud profile with correct paths" do
      profile = ServerDetector.get_server_profile(:owncloud)

      assert profile.type == :owncloud
      assert profile.discovery_path == "/remote.php/dav/calendars/{username}/"
      assert profile.supports_oauth == true
    end

    test "returns Baikal profile with correct paths" do
      profile = ServerDetector.get_server_profile(:baikal)

      assert profile.type == :baikal
      assert profile.discovery_path == "/dav.php/calendars/{username}/"
      assert profile.calendar_path_pattern == "/dav.php/calendars/{username}/{calendar}/"
      refute profile.supports_oauth
    end

    test "returns Baikal legacy profile with correct paths" do
      profile = ServerDetector.get_server_profile(:baikal_legacy)

      assert profile.type == :baikal_legacy
      assert profile.discovery_path == "/cal.php/calendars/{username}/"
      assert profile.calendar_path_pattern == "/cal.php/calendars/{username}/{calendar}/"
      assert profile.event_path_pattern == "/cal.php/calendars/{username}/{calendar}/{uid}.ics"
      refute profile.supports_oauth
    end

    test "returns SabreDAV profile with correct paths" do
      profile = ServerDetector.get_server_profile(:sabredav)

      assert profile.type == :sabredav
      assert profile.discovery_path == "/calendars/{username}/"
      assert profile.calendar_path_pattern == "/calendars/{username}/{calendar}/"
    end

    test "returns Zimbra profile with correct paths" do
      profile = ServerDetector.get_server_profile(:zimbra)

      assert profile.type == :zimbra
      assert profile.discovery_path == "/dav/{username}/"
      assert profile.calendar_path_pattern == "/dav/{username}/{calendar}/"
      assert profile.event_path_pattern == "/dav/{username}/{calendar}/{uid}.ics"
      refute profile.supports_oauth
      assert profile.supports_calendar_color == true
    end

    test "returns generic CalDAV profile for unknown types" do
      profile = ServerDetector.get_server_profile(:unknown)

      assert profile.type == :generic
      assert profile.discovery_path == "/"
      assert profile.calendar_path_pattern == "/{calendar}/"
      refute profile.supports_oauth
      assert profile.supports_calendar_color
    end
  end

  describe "build_discovery_url/3" do
    test "builds correct URL for Radicale" do
      url = ServerDetector.build_discovery_url("https://radicale.example.com", "user", :radicale)
      assert url == "https://radicale.example.com/user/"
    end

    test "builds correct URL for Nextcloud" do
      url = ServerDetector.build_discovery_url("https://cloud.example.com", "user", :nextcloud)
      assert url == "https://cloud.example.com/remote.php/dav/calendars/user/"
    end

    test "builds correct URL for Baikal" do
      url = ServerDetector.build_discovery_url("https://cal.example.com", "user", :baikal)
      assert url == "https://cal.example.com/dav.php/calendars/user/"
    end

    test "builds correct URL for Baikal legacy" do
      url = ServerDetector.build_discovery_url("https://cal.example.com", "user", :baikal_legacy)
      assert url == "https://cal.example.com/cal.php/calendars/user/"
    end

    test "builds correct URL for Zimbra" do
      url =
        ServerDetector.build_discovery_url(
          "https://mail.example.com",
          "user@example.com",
          :zimbra
        )

      assert url == "https://mail.example.com/dav/user@example.com/"
    end

    test "builds correct URL for generic CalDAV" do
      url = ServerDetector.build_discovery_url("https://caldav.example.com", "user", :generic)
      assert url == "https://caldav.example.com/"
    end

    test "removes trailing slash from base URL" do
      url = ServerDetector.build_discovery_url("https://radicale.example.com/", "user", :radicale)
      assert url == "https://radicale.example.com/user/"
    end
  end

  describe "build_calendar_url/4" do
    test "builds correct calendar URL for Radicale" do
      url =
        ServerDetector.build_calendar_url(
          "https://radicale.example.com",
          "user",
          "personal",
          :radicale
        )

      assert url == "https://radicale.example.com/user/personal/"
    end

    test "builds correct calendar URL for Nextcloud" do
      url =
        ServerDetector.build_calendar_url(
          "https://cloud.example.com",
          "user",
          "personal",
          :nextcloud
        )

      assert url == "https://cloud.example.com/remote.php/dav/calendars/user/personal/"
    end

    test "builds correct calendar URL for Baikal legacy" do
      url =
        ServerDetector.build_calendar_url(
          "https://cal.example.com",
          "user",
          "personal",
          :baikal_legacy
        )

      assert url == "https://cal.example.com/cal.php/calendars/user/personal/"
    end

    test "builds correct calendar URL for Zimbra" do
      url =
        ServerDetector.build_calendar_url(
          "https://mail.example.com",
          "user@example.com",
          "Calendar",
          :zimbra
        )

      assert url == "https://mail.example.com/dav/user@example.com/Calendar/"
    end

    test "builds correct calendar URL for generic CalDAV" do
      url =
        ServerDetector.build_calendar_url(
          "https://caldav.example.com",
          "user",
          "personal",
          :generic
        )

      assert url == "https://caldav.example.com/personal/"
    end
  end

  describe "build_event_url/5" do
    test "builds correct event URL for Radicale" do
      url =
        ServerDetector.build_event_url(
          "https://radicale.example.com",
          "user",
          "personal",
          "event-123",
          :radicale
        )

      assert url == "https://radicale.example.com/user/personal/event-123.ics"
    end

    test "builds correct event URL for Nextcloud" do
      url =
        ServerDetector.build_event_url(
          "https://cloud.example.com",
          "user",
          "personal",
          "event-123",
          :nextcloud
        )

      assert url ==
               "https://cloud.example.com/remote.php/dav/calendars/user/personal/event-123.ics"
    end

    test "builds correct event URL for Baikal legacy" do
      url =
        ServerDetector.build_event_url(
          "https://cal.example.com",
          "user",
          "personal",
          "event-123",
          :baikal_legacy
        )

      assert url == "https://cal.example.com/cal.php/calendars/user/personal/event-123.ics"
    end

    test "builds correct event URL for Zimbra" do
      url =
        ServerDetector.build_event_url(
          "https://mail.example.com",
          "user@example.com",
          "Calendar",
          "event-123",
          :zimbra
        )

      assert url == "https://mail.example.com/dav/user@example.com/Calendar/event-123.ics"
    end

    test "adds .ics extension if not present" do
      url =
        ServerDetector.build_event_url(
          "https://caldav.example.com",
          "user",
          "personal",
          "event-123",
          :generic
        )

      assert url == "https://caldav.example.com/personal/event-123.ics"
    end

    test "does not duplicate .ics extension" do
      url =
        ServerDetector.build_event_url(
          "https://caldav.example.com",
          "user",
          "personal",
          "event-123.ics",
          :generic
        )

      assert url == "https://caldav.example.com/personal/event-123.ics"
    end
  end
end
