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

  # Every server type `get_server_profile/1` answers for, paired with the URLs
  # the three builders must produce for it. A table because the behaviour is
  # identical across servers and only the data varies: written out per server it
  # ran to ~130 lines that covered five of the ten profiles, leaving ownCloud,
  # SabreDAV, Baikal, mailbox.org and Apple with no pin on their paths at all. A
  # typo in one of those would have shipped, and a self-hoster's calendar would
  # 404 with nothing red here.
  #
  # `{server_type, username, calendar, discovery_url, calendar_url, event_url}`.
  @base_url "https://cal.example.com"
  @server_urls [
    {:radicale, "user", "personal", "https://cal.example.com/user/",
     "https://cal.example.com/user/personal/",
     "https://cal.example.com/user/personal/event-123.ics"},
    {:nextcloud, "user", "personal", "https://cal.example.com/remote.php/dav/calendars/user/",
     "https://cal.example.com/remote.php/dav/calendars/user/personal/",
     "https://cal.example.com/remote.php/dav/calendars/user/personal/event-123.ics"},
    {:owncloud, "user", "personal", "https://cal.example.com/remote.php/dav/calendars/user/",
     "https://cal.example.com/remote.php/dav/calendars/user/personal/",
     "https://cal.example.com/remote.php/dav/calendars/user/personal/event-123.ics"},
    {:baikal, "user", "personal", "https://cal.example.com/dav.php/calendars/user/",
     "https://cal.example.com/dav.php/calendars/user/personal/",
     "https://cal.example.com/dav.php/calendars/user/personal/event-123.ics"},
    {:baikal_legacy, "user", "personal", "https://cal.example.com/cal.php/calendars/user/",
     "https://cal.example.com/cal.php/calendars/user/personal/",
     "https://cal.example.com/cal.php/calendars/user/personal/event-123.ics"},
    {:sabredav, "user", "personal", "https://cal.example.com/calendars/user/",
     "https://cal.example.com/calendars/user/personal/",
     "https://cal.example.com/calendars/user/personal/event-123.ics"},
    {:zimbra, "user@example.com", "Calendar", "https://cal.example.com/dav/user@example.com/",
     "https://cal.example.com/dav/user@example.com/Calendar/",
     "https://cal.example.com/dav/user@example.com/Calendar/event-123.ics"},
    # mailbox.org and Apple ignore the username: the path carries no {username}
    # placeholder, because calendars are reached through discovery rather than
    # guessed from the account name.
    {:mailbox_org, "user", "personal", "https://cal.example.com/caldav/",
     "https://cal.example.com/caldav/personal/",
     "https://cal.example.com/caldav/personal/event-123.ics"},
    {:apple, "user", "personal", "https://cal.example.com/", "https://cal.example.com/personal/",
     "https://cal.example.com/personal/event-123.ics"},
    # Anything unrecognised falls through to the generic profile, which appends
    # nothing but the calendar: the user supplied the full principal URL.
    {:generic, "user", "personal", "https://cal.example.com/",
     "https://cal.example.com/personal/", "https://cal.example.com/personal/event-123.ics"}
  ]

  describe "build_discovery_url/3, build_calendar_url/4 and build_event_url/5" do
    for {server_type, username, calendar, discovery_url, calendar_url, event_url} <- @server_urls do
      test "builds every URL from the #{server_type} profile's path patterns" do
        assert ServerDetector.build_discovery_url(
                 @base_url,
                 unquote(username),
                 unquote(server_type)
               ) == unquote(discovery_url)

        assert ServerDetector.build_calendar_url(
                 @base_url,
                 unquote(username),
                 unquote(calendar),
                 unquote(server_type)
               ) == unquote(calendar_url)

        assert ServerDetector.build_event_url(
                 @base_url,
                 unquote(username),
                 unquote(calendar),
                 "event-123",
                 unquote(server_type)
               ) == unquote(event_url)
      end
    end

    test "an unrecognised server type falls back to the generic profile" do
      # `get_server_profile/1` ends in a catch-all clause, so this is the path a
      # server we have never heard of takes.
      assert ServerDetector.build_discovery_url(@base_url, "user", :not_a_caldav_server) ==
               "#{@base_url}/"

      assert ServerDetector.build_calendar_url(
               @base_url,
               "user",
               "personal",
               :not_a_caldav_server
             ) ==
               "#{@base_url}/personal/"
    end

    test "trims a trailing slash from the base URL before joining" do
      assert ServerDetector.build_discovery_url("#{@base_url}/", "user", :radicale) ==
               "#{@base_url}/user/"

      assert ServerDetector.build_calendar_url("#{@base_url}/", "user", "personal", :radicale) ==
               "#{@base_url}/user/personal/"
    end

    test "adds the .ics extension to a bare event uid" do
      assert ServerDetector.build_event_url(@base_url, "user", "personal", "event-123", :generic) ==
               "#{@base_url}/personal/event-123.ics"
    end

    test "does not duplicate the .ics extension" do
      assert ServerDetector.build_event_url(
               @base_url,
               "user",
               "personal",
               "event-123.ics",
               :generic
             ) == "#{@base_url}/personal/event-123.ics"
    end
  end
end
