defmodule Tymeslot.Integrations.Calendar.DiscoveryCacheKeyTest do
  @moduledoc """
  A cached CalDAV discovery answer is served without reaching the server, so
  it is only ever served to the request that produced it: the same requester,
  address and credentials. Anything else goes to the server, where a wrong
  password is refused.
  """

  # async: false so `Mox.set_mox_from_context/1` (called by DataCase) puts the
  # mock in global mode: the PROPFIND runs inside a circuit-breaker process
  # that has no Mox allowance in private mode.
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar.Discovery
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryCache
  alias Tymeslot.Integrations.Calendar.Shared.DiscoveryService

  setup :verify_on_exit!

  @propfind_response """
  <D:multistatus xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
    <D:response>
      <D:href>/calendars/alice/personal/</D:href>
      <D:propstat>
        <D:prop>
          <D:displayname>Personal</D:displayname>
          <D:resourcetype><D:collection/><C:calendar/></D:resourcetype>
        </D:prop>
        <D:status>HTTP/1.1 200 OK</D:status>
      </D:propstat>
    </D:response>
  </D:multistatus>
  """

  setup do
    DiscoveryCache.clear_all()
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn _method, _url, _body, _headers, _opts ->
      send(test_pid, :reached_server)
      {:ok, %Req.Response{status: 207, body: @propfind_response}}
    end)

    :ok
  end

  defp config(password) do
    %{base_url: "https://dav.example.com/dav/", username: "alice", password: password}
  end

  defp discover(user_id, config),
    do: Discovery.discover_calendars(:caldav, config, actor: {:user, user_id})

  defp server_requests do
    receive do
      :reached_server -> 1 + server_requests()
    after
      0 -> 0
    end
  end

  test "repeats an identical request from the cache" do
    assert {:ok, [_calendar]} = discover(101, config("right"))
    first = server_requests()
    assert first > 0

    assert {:ok, [_calendar]} = discover(101, config("right"))
    assert server_requests() == 0
  end

  test "sends a request with another password to the server" do
    assert {:ok, _calendars} = discover(102, config("right"))
    assert server_requests() > 0

    assert {:ok, _calendars} = discover(102, config("guess"))
    assert server_requests() > 0
  end

  test "sends another user's request for the same account to the server" do
    assert {:ok, _calendars} = discover(103, config("right"))
    assert server_requests() > 0

    assert {:ok, _calendars} = discover(104, config("right"))
    assert server_requests() > 0
  end

  test "sends a request for another path on the same host to the server" do
    assert {:ok, _calendars} = discover(105, config("right"))
    assert server_requests() > 0

    other_path = %{config("right") | base_url: "https://dav.example.com/other-tenant/dav/"}
    assert {:ok, _calendars} = discover(105, other_path)
    assert server_requests() > 0
  end

  test "keeps no credential or address in the key" do
    key = DiscoveryService.build_cache_key(:caldav, config("s3cret-pass"), {:user, 105})
    rendered = inspect(key, limit: :infinity, printable_limit: :infinity)

    refute rendered =~ "s3cret-pass"
    refute rendered =~ "alice"
    refute rendered =~ "dav.example.com"
  end
end
