defmodule Tymeslot.Integrations.Calendar.DiscoveryHappyPathTest do
  # async: false so `Mox.set_mox_from_context/1` (called by DataCase) puts the
  # mock in global mode. The CalDAV discovery chain runs the HTTP call inside
  # a circuit-breaker GenServer process; in private (async: true) mode that
  # process has no Mox allowance and the stub is bypassed in favour of the
  # default :timeout fallback, so the success branch never fires.
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryCache
  alias Tymeslot.Integrations.CalendarManagement
  import Mox
  import Tymeslot.Factory

  setup :verify_on_exit!

  # `DiscoveryCache` is a shared, process-wide ETS table keyed on
  # `{provider, "username@host"}`. Both tests below reuse the same
  # "user"@"caldav.example.com" fixture, so a cached result left over from
  # another suite run (or a prior run of this same test) would return stale
  # (or partial) `calendar_paths` instead of exercising the stubbed PROPFIND
  # response this file sets up. Clearing it here keeps this file's two tests
  # deterministic without touching shared test support.
  setup do
    DiscoveryCache.clear_all()
    :ok
  end

  @propfind_calendar_response """
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/calendars/user/work/</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname>Work</D:displayname>
          <D:resourcetype>
            <D:collection/>
            <C:calendar/>
          </D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
    <D:response>
      <D:href>/calendars/user/personal/</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname>Personal</D:displayname>
          <D:resourcetype>
            <D:collection/>
            <C:calendar/>
          </D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  describe "maybe_discover_calendars/1 — discovered paths injected into attrs" do
    test "writes :calendar_paths into atom-keyed attrs on a successful PROPFIND" do
      # The other `maybe_discover_calendars/1` tests all hit the silent-failure
      # branch (invalid URL → discovery fails → attrs returned unchanged), so
      # the success arm that actually writes discovered paths back into attrs
      # is unverified. This test pins that arm: a stubbed 207 PROPFIND with
      # two calendars must produce attrs whose `:calendar_paths` matches the
      # hrefs from the response.
      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: @propfind_calendar_response}}
      end)

      # `discover_caldav_calendar_paths/1` charges the discovery request to
      # `{:user, attrs[:user_id]}` — the rate limiter only needs a positive
      # integer (no DB row lookup, see `RateLimiter.Integrations.scope_key/1`),
      # so a plain id is enough here; unlike the end-to-end test below, this
      # one never persists anything.
      attrs = %{
        provider: "caldav",
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        user_id: 1
      }

      assert {:ok, %{calendar_paths: paths} = result} = Discovery.maybe_discover_calendars(attrs)
      assert Enum.sort(paths) == ["/calendars/user/personal/", "/calendars/user/work/"]
      # Other fields are preserved unchanged.
      assert result.provider == "caldav"
      assert result.username == "user"
    end
  end

  describe "CalendarManagement.create_calendar_integration/1 — end-to-end discovery" do
    test "creates a CalDAV-family integration and persists discovered calendar_paths" do
      # The user-visible scenario: a user creates a CalDAV-family integration
      # with no pre-selected calendars, the server has calendars, and the
      # integration must end up persisted with `calendar_paths` populated.
      # Any break between `Discovery.maybe_discover_calendars/1` and the
      # persisted record (e.g. `cast/3` silently dropping the field,
      # `PrimarySelection.create_with_auto_primary/1` ignoring injected
      # paths) would not be caught by per-helper unit tests.
      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: @propfind_calendar_response}}
      end)

      user = insert(:user)
      _profile = insert(:profile, user: user)

      attrs = %{
        user_id: user.id,
        name: "My CalDAV",
        provider: "caldav",
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: [],
        provider_account_id: "https://caldav.example.com||user",
        is_active: true
      }

      assert {:ok, integration} = CalendarManagement.create_calendar_integration(attrs)

      assert Enum.sort(integration.calendar_paths) == [
               "/calendars/user/personal/",
               "/calendars/user/work/"
             ]

      assert integration.provider == "caldav"
      assert integration.user_id == user.id
    end
  end
end
