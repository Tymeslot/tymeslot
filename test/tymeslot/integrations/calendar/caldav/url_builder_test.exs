defmodule Tymeslot.Integrations.Calendar.CalDAV.UrlBuilderTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalDAV.UrlBuilder
  alias Tymeslot.Integrations.Calendar.Nextcloud.Provider, as: NextcloudProvider

  describe "build_discovery_url/1" do
    # Regression: `Nextcloud.Provider.new/1` normalises a bare host through
    # `Shared.PathUtils.normalize_url/2`, which turns
    # "https://cloud.example.com" into "https://cloud.example.com/remote.php/dav"
    # — a 2-segment path. `full_caldav_url?/1` treated any path of depth >= 2 as
    # an already-specific calendar collection URL and skipped appending
    # "/calendars/{username}/", so discovery queried the bare CalDAV *service
    # root* instead of the user's calendar-home-set. That root's PROPFIND
    # response lists top-level collections (files/, addressbooks/,
    # calendars/, ...) that never carry a `<cal:calendar/>` resourcetype, so
    # every Nextcloud discovery silently returned zero calendars — a real
    # 2xx response, correctly parsed, just for the wrong resource — with no
    # error surfaced anywhere. Confirmed live: the guessed path became
    # `.../remote.php/dav/` instead of `.../remote.php/dav/calendars/alice/`.
    test "appends /calendars/{username}/ for a bare Nextcloud host, even after Provider.new/1 normalisation" do
      client =
        NextcloudProvider.new(%{
          base_url: "https://cloud.example.com",
          username: "alice",
          password: "x"
        })

      assert UrlBuilder.build_discovery_url(client) ==
               "https://cloud.example.com/remote.php/dav/calendars/alice/"
    end

    # Nextcloud is frequently installed in a subdirectory rather than at the
    # domain root, where the same normalisation yields
    # "/nextcloud/remote.php/dav", a three-segment path. Matching the service
    # root as an exact path rather than a suffix would miss those installations
    # and leave them on the broken path described above.
    test "appends /calendars/{username}/ for a subdirectory Nextcloud install" do
      client =
        NextcloudProvider.new(%{
          base_url: "https://example.com/nextcloud/remote.php/dav",
          username: "alice",
          password: "x"
        })

      assert UrlBuilder.build_discovery_url(client) ==
               "https://example.com/nextcloud/remote.php/dav/calendars/alice/"
    end

    test "does not double-append when base_url already includes /calendars/{username}" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav/calendars/alice",
        username: "alice",
        provider: :nextcloud
      }

      assert UrlBuilder.build_discovery_url(client) ==
               "https://cloud.example.com/remote.php/dav/calendars/alice/"
    end

    test "treats a user-pasted full calendar collection path as already specific" do
      client = %{
        base_url: "https://cloud.example.com/remote.php/dav/calendars/alice/personal",
        username: "alice",
        provider: :nextcloud
      }

      assert UrlBuilder.build_discovery_url(client) ==
               "https://cloud.example.com/remote.php/dav/calendars/alice/personal/"
    end

    test "appends /{username}/ for a bare Radicale host" do
      client = %{base_url: "https://radicale.example.com", username: "alice", provider: :radicale}

      assert UrlBuilder.build_discovery_url(client) ==
               "https://radicale.example.com/alice/"
    end
  end

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
