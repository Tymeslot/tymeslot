defmodule Tymeslot.Infrastructure.HTTPClientSsrfTest do
  @moduledoc """
  Tests the request-time SSRF guard wired into `HTTPClient` via the
  `ssrf_protect: true` option (used by the CalDAV transport and self-hosted
  MiroTalk). The guard runs in `:prod`, so these tests pin the environment.
  """

  use ExUnit.Case, async: false

  @moduletag :infrastructure
  @moduletag :security

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Security.SsrfBlockedError

  setup do
    original_env = fetch_config(:environment)
    original_resolver = fetch_config(:dns_resolver_module)
    original_allow = fetch_config(:allow_private_ips_for_calendar)

    Application.put_env(:tymeslot, :environment, :prod)
    Application.put_env(:tymeslot, :allow_private_ips_for_calendar, false)

    on_exit(fn ->
      restore(:environment, original_env)
      restore(:dns_resolver_module, original_resolver)
      restore(:allow_private_ips_for_calendar, original_allow)
    end)

    :ok
  end

  defp fetch_config(key) do
    case Application.fetch_env(:tymeslot, key) do
      {:ok, value} -> {:set, value}
      :error -> :unset
    end
  end

  defp restore(key, :unset), do: Application.delete_env(:tymeslot, key)
  defp restore(key, {:set, value}), do: Application.put_env(:tymeslot, key, value)

  test "blocks an SSRF-protected request whose host resolves to a private address" do
    Application.put_env(:tymeslot, :dns_resolver_module, HttpClientPrivateResolver)

    ReqTest.stub(:tymeslot_http, fn _conn ->
      flunk("network request must not be made for a blocked host")
    end)

    assert {:error, %SsrfBlockedError{}} =
             HTTPClient.request(:get, "https://rebind.example.com/", "", [], ssrf_protect: true)
  end

  test "permits an SSRF-protected request to a public host" do
    Application.put_env(:tymeslot, :dns_resolver_module, HttpClientOkResolver)

    ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 207, "<xml/>") end)

    assert {:ok, %Req.Response{status: 207}} =
             HTTPClient.request(:propfind, "https://caldav.example.com/", "", [],
               ssrf_protect: true
             )
  end

  test "does not apply the guard when ssrf_protect is absent" do
    Application.put_env(:tymeslot, :dns_resolver_module, HttpClientPrivateResolver)

    ReqTest.stub(:tymeslot_http, fn conn -> Conn.send_resp(conn, 200, "ok") end)

    assert {:ok, %Req.Response{status: 200}} =
             HTTPClient.request(:get, "https://rebind.example.com/", "", [])
  end

  # Gap H — redirect: false must remain on the guarded path.
  #
  # A 3xx from a public host must NOT be followed when ssrf_protect: true is
  # set: Req would otherwise transparently send a second request to the
  # Location header's host, which an attacker could point at an internal address
  # (open-redirect SSRF bypass).  Dropping `redirect: false` from guarded_request
  # would make this test fail because Req follows redirects by default.
  test "guarded request does not follow a 3xx redirect — redirect: false prevents open-redirect SSRF bypass" do
    Application.put_env(:tymeslot, :dns_resolver_module, HttpClientOkResolver)

    # Track whether a second request to the internal host is attempted.
    # With redirect: false in place, only one request is made and the 302 is
    # returned directly.  Without it, Req would follow the Location header and
    # a second call to the stub would arrive.
    request_count = :counters.new(1, [:atomics])

    ReqTest.stub(:tymeslot_http, fn conn ->
      :counters.add(request_count, 1, 1)
      n = :counters.get(request_count, 1)

      if n > 1 do
        flunk("redirect was followed — a second request reached the internal host")
      end

      conn
      |> Conn.put_resp_header("location", "http://169.254.169.254/latest/meta-data/")
      |> Conn.send_resp(302, "")
    end)

    assert {:ok, %Req.Response{status: 302}} =
             HTTPClient.request(:get, "https://public.example.com/resource", "", [],
               ssrf_protect: true
             )

    # Confirm that exactly one outbound request was made (no redirect followed).
    assert :counters.get(request_count, 1) == 1
  end
end

defmodule HttpClientOkResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts), do: :ok
end

defmodule HttpClientPrivateResolver do
  @moduledoc false
  @behaviour Tymeslot.Security.DnsResolutionBehaviour

  @impl Tymeslot.Security.DnsResolutionBehaviour
  def check_private_ip(_url, _opts),
    do: {:error, "URL resolves to a private or local network address"}
end
