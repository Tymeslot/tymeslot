defmodule TymeslotWeb.EndpointRemoteIpTest do
  # Toggles :trust_private_client_ips and :trusted_proxies, which ClientIP reads
  # on every request and LiveView mount, so this module cannot run beside other
  # tests.
  use TymeslotWeb.ConnCase, async: false

  @moduletag :security
  @moduletag :infrastructure

  import Tymeslot.ConfigTestHelpers

  # Requests go through the whole endpoint, so these pin what the `RemoteIp`
  # plug is actually given rather than what `RemoteIp.from/2` does with options
  # a test hands it. `build_conn/0` connects from 127.0.0.1, which stands in for
  # the reverse proxy in front of the release.

  defp remote_ip_for(conn, headers) do
    headers
    |> Enum.reduce(conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)
    |> get("/healthcheck")
    |> Map.fetch!(:remote_ip)
  end

  test "resolves the visitor from x-forwarded-for behind a local proxy", %{conn: conn} do
    assert remote_ip_for(conn, [{"x-forwarded-for", "203.0.113.9, 10.0.0.1"}]) ==
             {203, 0, 113, 9}
  end

  test "ignores forwarded headers the socket path does not read", %{conn: conn} do
    # Both are in RemoteIp's default header list. A client whose proxy passes
    # them through could otherwise choose its own rate-limit key.
    assert remote_ip_for(conn, [{"x-client-ip", "198.51.100.7"}]) == {127, 0, 0, 1}
    assert remote_ip_for(conn, [{"forwarded", "for=198.51.100.7"}]) == {127, 0, 0, 1}
  end

  test "treats a private forwarded address as a proxy hop by default", %{conn: conn} do
    with_config(:tymeslot, :trust_private_client_ips, false)

    assert remote_ip_for(conn, [{"x-forwarded-for", "192.168.1.10"}]) == {127, 0, 0, 1}
  end

  test "TRUST_PRIVATE_CLIENT_IPS gives LAN visitors their own address", %{conn: conn} do
    with_config(:tymeslot, :trust_private_client_ips, true)

    assert remote_ip_for(conn, [{"x-forwarded-for", "192.168.1.10"}]) == {192, 168, 1, 10}

    assert remote_ip_for(build_conn(), [{"x-forwarded-for", "fd00::11"}]) ==
             {0xFD00, 0, 0, 0, 0, 0, 0, 0x11}
  end

  # The table from issue #192: a CDN edge appends the visitor to
  # X-Forwarded-For and the reverse proxy names the edge in X-Real-IP. Headers
  # are put in the order listed, which is the order `RemoteIp` reads them.
  @edge_table [
    {[{"x-forwarded-for", "198.51.100.7"}, {"x-real-ip", "172.68.1.1"}], {198, 51, 100, 7}},
    {[{"x-real-ip", "172.68.1.1"}, {"x-forwarded-for", "198.51.100.7"}], {198, 51, 100, 7}},
    {[{"x-forwarded-for", "203.0.113.9"}], {203, 0, 113, 9}}
  ]

  test "TRUSTED_PROXIES skips the edge, whatever order the headers arrive in" do
    with_config(:tymeslot, :trusted_proxies, ["172.64.0.0/13"])

    for {headers, visitor} <- @edge_table do
      assert remote_ip_for(build_conn(), headers) == visitor, inspect(headers)
    end
  end

  test "without TRUSTED_PROXIES the edge in x-real-ip wins", %{conn: conn} do
    with_config(:tymeslot, :trusted_proxies, [])

    assert remote_ip_for(conn, [{"x-forwarded-for", "198.51.100.7"}, {"x-real-ip", "172.68.1.1"}]) ==
             {172, 68, 1, 1}
  end
end
