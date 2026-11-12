defmodule TymeslotWeb.Helpers.ClientIPTrustedProxiesTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Helpers.ClientIP

  @headers_opt [headers: ~w[x-forwarded-for x-real-ip]]
  @private_blocks ClientIP.remote_ip_clients(true)

  defp mock_socket(opts) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      transport_pid: self(),
      private: %{connect_info: Keyword.get(opts, :connect_info, %{}), connect_params: %{}}
    }
  end

  # A CDN in front of a reverse proxy: the edge appends the visitor to
  # X-Forwarded-For, and a proxy that sets X-Real-IP to its own peer names the
  # edge there. With nothing marking the edge's range as a proxy, its address is
  # the rightmost non-private entry and every visitor through that edge shares
  # it (issue #192). Every case resolves through both paths with the same
  # options and must land on the same address.
  describe "trusted proxy ranges on both paths" do
    @edge_ranges ["172.64.0.0/13", "2400:cb00::/32"]
    @inner_proxy %{address: {10, 0, 1, 5}, port: 0, ssl_cert: nil}
    @edge_peer %{address: {172, 68, 1, 1}, port: 0, ssl_cert: nil}

    # The address the conn path settles on: `RemoteIp`'s pick, or the peer when
    # it finds no client, which is what the plug leaves in `conn.remote_ip`.
    defp conn_path(headers, peer, trust_private_clients?, trusted_proxies) do
      opts =
        @headers_opt ++
          [
            clients: ClientIP.remote_ip_clients(trust_private_clients?),
            proxies: trusted_proxies
          ]

      (RemoteIp.from(headers, opts) || peer.address) |> :inet.ntoa() |> to_string()
    end

    defp socket_path(headers, peer, trust_private_clients?, trusted_proxies) do
      [connect_info: %{peer_data: peer, x_headers: headers}]
      |> mock_socket()
      |> ClientIP.get_from_mount(trust_private_clients?, trusted_proxies)
    end

    defp assert_paths_agree(headers, peer, expected, trust_private_clients? \\ false) do
      conn = conn_path(headers, peer, trust_private_clients?, @edge_ranges)
      socket = socket_path(headers, peer, trust_private_clients?, @edge_ranges)

      assert {conn, socket} == {expected, expected}, inspect(headers)
    end

    test "the issue's table resolves to the visitor on both paths" do
      for {headers, visitor} <- [
            {[{"x-forwarded-for", "198.51.100.7"}, {"x-real-ip", "172.68.1.1"}], "198.51.100.7"},
            {[{"x-real-ip", "172.68.1.1"}, {"x-forwarded-for", "198.51.100.7"}], "198.51.100.7"},
            {[{"x-forwarded-for", "203.0.113.9"}], "203.0.113.9"}
          ] do
        assert_paths_agree(headers, @inner_proxy, visitor)
      end
    end

    test "without trusted ranges the first row resolves to the edge on both paths" do
      # The behaviour the issue reports, pinned so the fix above is what moves it.
      headers = [{"x-forwarded-for", "198.51.100.7"}, {"x-real-ip", "172.68.1.1"}]

      assert conn_path(headers, @inner_proxy, false, []) == "172.68.1.1"
      assert socket_path(headers, @inner_proxy, false, []) == "172.68.1.1"
    end

    test "IPv6 edges are skipped the same way" do
      headers = [{"x-forwarded-for", "2001:db8::7"}, {"x-real-ip", "2400:cb00::1"}]

      assert_paths_agree(headers, @inner_proxy, "2001:db8::7")
    end

    test "a chain through several trusted hops resolves to the visitor" do
      headers = [{"x-forwarded-for", "198.51.100.7, 172.68.1.1, 172.70.9.9"}]

      assert_paths_agree(headers, @inner_proxy, "198.51.100.7")
    end

    test "a client-supplied head cannot displace the visitor the edge appended" do
      headers = [{"x-forwarded-for", "203.0.113.200, 198.51.100.7, 172.68.1.1"}]

      assert_paths_agree(headers, @inner_proxy, "198.51.100.7")
    end

    test "falls back to the peer when every forwarded entry is a trusted hop" do
      headers = [{"x-forwarded-for", "172.68.1.1"}, {"x-real-ip", "172.68.1.1"}]

      assert_paths_agree(headers, @inner_proxy, "10.0.1.5")
    end

    test "a peer in a trusted range forwards for the visitor with no private hop" do
      headers = [{"x-forwarded-for", "198.51.100.7"}]

      assert_paths_agree(headers, @edge_peer, "198.51.100.7")
    end

    test "an IPv4-mapped peer in a trusted range is trusted too" do
      mapped_edge = %{address: {0, 0, 0, 0, 0, 0xFFFF, 0xAC44, 0x0101}, port: 0, ssl_cert: nil}

      assert socket_path([{"x-forwarded-for", "198.51.100.7"}], mapped_edge, false, @edge_ranges) ==
               "198.51.100.7"
    end

    test "a public peer outside every trusted range still cannot forward" do
      headers = [{"x-forwarded-for", "198.51.100.7"}]
      direct = %{address: {203, 0, 113, 50}, port: 0, ssl_cert: nil}

      assert socket_path(headers, direct, false, @edge_ranges) == "203.0.113.50"
    end

    test "a private address listed as trusted is still a visitor when the flag is on" do
      # `clients:` outranks `proxies:` in `RemoteIp`, and the socket path keeps
      # the same order.
      headers = [{"x-forwarded-for", "192.168.1.10"}]
      opts = @headers_opt ++ [clients: @private_blocks, proxies: ["192.168.0.0/16"]]

      assert RemoteIp.from(headers, opts) == {192, 168, 1, 10}
      assert socket_path(headers, @inner_proxy, true, ["192.168.0.0/16"]) == "192.168.1.10"
    end

    test "with the flag on, trusted public hops are still skipped" do
      headers = [{"x-forwarded-for", "192.168.1.10, 172.68.1.1"}]

      assert_paths_agree(headers, @inner_proxy, "192.168.1.10", true)
    end

    test "get_from_mount/2 is get_from_mount/3 with no trusted ranges" do
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @inner_proxy,
            x_headers: [{"x-forwarded-for", "198.51.100.7"}, {"x-real-ip", "172.68.1.1"}]
          }
        )

      assert ClientIP.get_from_mount(socket, false) == ClientIP.get_from_mount(socket, false, [])
    end

    test "the proxies list is empty by default" do
      assert ClientIP.remote_ip_proxies() == []
    end
  end
end
