defmodule Tymeslot.Integrations.Calendar.Shared.PathUtilsTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Shared.PathUtils

  describe "ensure_scheme/1" do
    test "leaves valid https URLs untouched" do
      assert PathUtils.ensure_scheme("https://cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "leaves valid http URLs untouched" do
      assert PathUtils.ensure_scheme("http://cloud.example.com") ==
               "http://cloud.example.com"
    end

    test "prepends https:// to a bare host" do
      assert PathUtils.ensure_scheme("cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "normalises protocol-relative //host to https://host" do
      assert PathUtils.ensure_scheme("//cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "trims surrounding whitespace before checking the scheme" do
      assert PathUtils.ensure_scheme("  https://cloud.example.com  ") ==
               "https://cloud.example.com"
    end

    # Regression: a Nextcloud integration was once stored with base_url
    # "https://https:/" — the input was the malformed "https:/cloud.lukabreitig.com"
    # (single slash), which the old literal `starts_with?("https://")` check
    # missed, so "https://" was naively prepended a second time, producing
    # "https://https:/cloud.lukabreitig.com" and a host of "https". Guard
    # against any "https?:/*" prefix the input may already carry.
    test "repairs https with a single slash and no host" do
      refute String.starts_with?(PathUtils.ensure_scheme("https:/"), "https://https")
    end

    test "repairs https:/host (single slash) without doubling the scheme" do
      assert PathUtils.ensure_scheme("https:/cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "repairs https:host (no slashes) without doubling the scheme" do
      assert PathUtils.ensure_scheme("https:cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "repairs http:/host (single slash)" do
      assert PathUtils.ensure_scheme("http:/cloud.example.com") ==
               "https://cloud.example.com"
    end
  end

  describe "normalize_base_url/1" do
    # Regression for Tymeslot#45: the previous normaliser used a full-string
    # regex `/cloud.*$` that matched the second slash of "https://cloud…",
    # stripping the hostname entirely and producing "https:/", which then
    # failed URL validation with a misleading "Must be a valid HTTP or HTTPS
    # URL" error on submit. These three are the common Nextcloud subdomains
    # and must survive normalisation untouched.
    test "preserves Nextcloud-style subdomains" do
      assert PathUtils.normalize_base_url("https://cloud.example.com") ==
               "https://cloud.example.com"

      assert PathUtils.normalize_base_url("https://nextcloud.example.com") ==
               "https://nextcloud.example.com"

      assert PathUtils.normalize_base_url("https://owncloud.example.com") ==
               "https://owncloud.example.com"
    end

    test "adds https:// when the input has no scheme" do
      assert PathUtils.normalize_base_url("cloud.example.com") ==
               "https://cloud.example.com"
    end

    test "drops a lone trailing slash" do
      assert PathUtils.normalize_base_url("https://cloud.example.com/") ==
               "https://cloud.example.com"
    end

    test "strips a /remote.php/dav CalDAV endpoint suffix" do
      assert PathUtils.normalize_base_url(
               "https://cloud.example.com/remote.php/dav/calendars/user/personal/"
             ) == "https://cloud.example.com"
    end

    test "strips a /remote.php/webdav suffix" do
      assert PathUtils.normalize_base_url("https://cloud.example.com/remote.php/webdav/") ==
               "https://cloud.example.com"
    end

    test "strips a browser-pasted /apps/* URL" do
      assert PathUtils.normalize_base_url(
               "https://cloud.example.com/apps/calendar/dayGridMonth/2026-04-20"
             ) == "https://cloud.example.com"
    end

    test "strips an /index.php front-controller URL" do
      assert PathUtils.normalize_base_url("https://cloud.example.com/index.php/settings/user") ==
               "https://cloud.example.com"
    end

    test "preserves a subpath install" do
      assert PathUtils.normalize_base_url("https://example.com/nextcloud") ==
               "https://example.com/nextcloud"
    end

    test "strips CalDAV suffix but keeps the subpath install" do
      assert PathUtils.normalize_base_url(
               "https://example.com/nextcloud/remote.php/dav/calendars/user/"
             ) == "https://example.com/nextcloud"
    end

    test "strips /apps suffix but keeps the subpath install" do
      assert PathUtils.normalize_base_url("https://example.com/nextcloud/apps/calendar/") ==
               "https://example.com/nextcloud"
    end

    test "preserves a non-standard port" do
      assert PathUtils.normalize_base_url(
               "https://example.com:8443/remote.php/dav/calendars/user/"
             ) == "https://example.com:8443"
    end

    test "returns scheme-repaired input when no host can be parsed" do
      # Downstream URLValidator rejects this; normalize_base_url stays out of
      # the way rather than silently producing "https://".
      assert PathUtils.normalize_base_url("not a url") == "https://not a url"
    end

    # Security regression: the pre-refactor ensure_scheme/URLValidator pair
    # rejected javascript: URLs because the whole original string was kept
    # and URLValidator scanned it for the "javascript:" substring. A naive
    # refactor that parses-and-rebuilds the URL silently drops the payload
    # (e.g. "https://javascript:alert(1)" → "https://javascript") and makes
    # the URL pass validation. Disallowed schemes must round-trip intact.
    test "does not rewrite javascript:, file:, data:, or ftp: URLs" do
      for bad <- [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,<script>alert(1)</script>",
            "ftp://example.com/file"
          ] do
        assert PathUtils.normalize_base_url(bad) == bad
      end
    end
  end

  # `normalize_url(url, provider: :nextcloud)` is what turns whatever a user
  # pastes into the connect form into the base the CalDAV client queries, so a
  # wrong result here is invisible: discovery still returns a well-formed 2xx,
  # just for a resource that holds no calendars.
  #
  # Subdirectory installs were broken in both directions before this block
  # existed. A browser-pasted app route was reduced to `scheme://host`, silently
  # dropping the subdirectory; and a bare subdirectory host was left untouched,
  # so the DAV endpoint was never appended at all.
  describe "normalize_url/2 with provider: :nextcloud" do
    test "appends the DAV endpoint to a bare host" do
      assert PathUtils.normalize_url("https://cloud.example.com", provider: :nextcloud) ==
               "https://cloud.example.com/remote.php/dav/"
    end

    test "appends the DAV endpoint to a subdirectory install" do
      assert PathUtils.normalize_url("https://example.com/nextcloud", provider: :nextcloud) ==
               "https://example.com/nextcloud/remote.php/dav/"
    end

    test "keeps the subdirectory when stripping a browser-pasted app route" do
      assert PathUtils.normalize_url("https://example.com/nextcloud/apps/calendar",
               provider: :nextcloud
             ) == "https://example.com/nextcloud/remote.php/dav/"
    end

    test "keeps the subdirectory when stripping an index.php front-controller URL" do
      assert PathUtils.normalize_url("https://example.com/nextcloud/index.php/apps/calendar",
               provider: :nextcloud
             ) == "https://example.com/nextcloud/remote.php/dav/"
    end

    test "leaves a URL that already points inside the DAV endpoint untouched" do
      assert PathUtils.normalize_url(
               "https://example.com/nextcloud/remote.php/dav/calendars/alice/personal",
               provider: :nextcloud
             ) == "https://example.com/nextcloud/remote.php/dav/calendars/alice/personal/"
    end

    test "preserves a non-standard port" do
      assert PathUtils.normalize_url("https://cloud.example.com:8443", provider: :nextcloud) ==
               "https://cloud.example.com:8443/remote.php/dav/"
    end
  end
end
