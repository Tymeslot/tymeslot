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
  # response this file sets up. Clearing it here keeps this file's tests
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

  @propfind_empty_response """
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
  </D:multistatus>
  """

  describe "maybe_discover_calendars/1 — discovered paths injected into attrs" do
    test "writes :calendar_paths into atom-keyed attrs on a successful PROPFIND" do
      # The other `maybe_discover_calendars/1` tests all hit the refusal branch
      # (invalid URL → discovery fails → nothing to sync), so the success arm
      # that actually writes the discovered selection back into attrs is
      # unverified. This test pins that arm: a stubbed 207 PROPFIND with two
      # calendars must produce attrs whose `:calendar_paths` matches the hrefs
      # from the response.
      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: @propfind_calendar_response}}
      end)

      # The discovery request is charged to
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

      # `calendar_paths` is derived from the `selected` flags on
      # `calendar_list` everywhere else, so the two must be written together.
      # Writing the paths alone left an empty list behind, from which the first
      # re-discovery derived an empty selection and wiped the paths again.
      assert Enum.sort(Enum.map(result.calendar_list, & &1.path)) == Enum.sort(paths)
      assert Enum.all?(result.calendar_list, & &1.selected)
      assert Enum.sort(Enum.map(result.calendar_list, & &1.name)) == ["Personal", "Work"]

      # Other fields are preserved unchanged.
      assert result.provider == "caldav"
      assert result.username == "user"
    end

    test "refuses attrs when the server answers a PROPFIND with no calendars" do
      # A server with no collections is not a transient failure: Tymeslot never
      # issues MKCALENDAR, so the account stays empty until its owner creates a
      # calendar in their own client. Saving the connection would present a row
      # that can never sync as working.
      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: @propfind_empty_response}}
      end)

      attrs = %{
        provider: "caldav",
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        user_id: 1
      }

      assert {:error, %{discovery: message}} = Discovery.maybe_discover_calendars(attrs)
      assert message =~ "No calendars were discovered"
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

      # Persisted together with the paths: a row whose `calendar_list` is
      # empty has its paths wiped by the first re-discovery, since that derives
      # the selection from the list.
      assert Enum.sort(Enum.map(integration.calendar_list, & &1.path)) ==
               Enum.sort(integration.calendar_paths)

      assert Enum.all?(integration.calendar_list, & &1.selected)

      assert integration.provider == "caldav"
      assert integration.user_id == user.id
    end

    test "does not persist an integration when the server has no calendars" do
      # A CalDAV account with no calendars used to be saved as if the
      # connection had succeeded, leaving a row that could never sync and had
      # no calendar to book into. The failure now reaches the connection form,
      # where the person can still act on it.
      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 207, body: @propfind_empty_response}}
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

      assert {:error, %{discovery: _message}} =
               CalendarManagement.create_calendar_integration(attrs)

      assert CalendarManagement.list_calendar_integrations(user.id) == []
    end

    test "a retry after creating a calendar on the server is not refused from the cache" do
      # The refusal tells the person to create a calendar and try again. Had
      # the empty discovery been cached, the retry would have been answered
      # from it and refused for the whole TTL, however many calendars the
      # server had gained since.
      responses = :counters.new(1, [])

      stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
        :counters.add(responses, 1, 1)

        body =
          if :counters.get(responses, 1) == 1,
            do: @propfind_empty_response,
            else: @propfind_calendar_response

        {:ok, %Req.Response{status: 207, body: body}}
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

      assert {:error, %{discovery: _message}} =
               CalendarManagement.create_calendar_integration(attrs)

      assert {:ok, integration} = CalendarManagement.create_calendar_integration(attrs)

      assert Enum.sort(integration.calendar_paths) == [
               "/calendars/user/personal/",
               "/calendars/user/work/"
             ]
    end
  end
end
