defmodule Tymeslot.Integrations.Calendar.CalDAV.UrlBuilderTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder

  describe "build_calendar_url/2" do
    test "resolves a server-root-relative href against the base origin" do
      assert UrlBuilder.build_calendar_url("https://cloud.example.com", "/calendars/me/") ==
               "https://cloud.example.com/calendars/me/"
    end

    test "uses only the base origin, dropping any base path, for root-relative hrefs" do
      assert UrlBuilder.build_calendar_url(
               "https://cloud.example.com/remote.php/dav",
               "/remote.php/dav/calendars/me/"
             ) == "https://cloud.example.com/remote.php/dav/calendars/me/"
    end

    test "appends a relative href to the full base_url" do
      assert UrlBuilder.build_calendar_url("https://cloud.example.com/dav", "calendars/me/") ==
               "https://cloud.example.com/dav/calendars/me/"
    end

    test "preserves a non-default port for root-relative hrefs" do
      assert UrlBuilder.build_calendar_url("https://cloud.example.com:8443", "/calendars/me/") ==
               "https://cloud.example.com:8443/calendars/me/"
    end

    # iCloud returns calendar-home-set as an ABSOLUTE URL on a per-user partition
    # host (e.g. https://p110-caldav.icloud.com/<dsid>/calendars/). The href must
    # be reduced to its path and pinned to the validated base host, not
    # concatenated onto base_url (which produced a malformed double-scheme URL
    # and broke every iCloud connection).
    test "pins an absolute partition-host href to the validated base origin (iCloud)" do
      assert UrlBuilder.build_calendar_url(
               "https://caldav.icloud.com",
               "https://p110-caldav.icloud.com:443/19428228001/calendars/"
             ) == "https://caldav.icloud.com/19428228001/calendars/"
    end

    test "keeps the query string when reducing an absolute href to its path" do
      assert UrlBuilder.build_calendar_url(
               "https://caldav.icloud.com",
               "https://p110-caldav.icloud.com/19428228001/calendars/?foo=bar"
             ) == "https://caldav.icloud.com/19428228001/calendars/?foo=bar"
    end

    test "treats an absolute href with an empty path as the origin root" do
      assert UrlBuilder.build_calendar_url(
               "https://caldav.icloud.com",
               "https://p110-caldav.icloud.com"
             ) == "https://caldav.icloud.com/"
    end
  end
end
