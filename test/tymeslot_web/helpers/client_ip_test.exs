defmodule TymeslotWeb.Helpers.ClientIPTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Helpers.ClientIP

  defp mock_socket(opts) do
    connected? = Keyword.get(opts, :connected?, true)
    connect_info = Keyword.get(opts, :connect_info, %{})
    connect_params = Keyword.get(opts, :connect_params, %{})

    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      transport_pid: if(connected?, do: self(), else: nil),
      private: %{
        connect_info: connect_info,
        connect_params: connect_params
      }
    }
  end

  defp mock_conn(opts) do
    remote_ip = Keyword.get(opts, :remote_ip, nil)
    headers = Keyword.get(opts, :headers, [])

    conn = %Plug.Conn{
      req_headers: headers,
      adapter: {Plug.Adapters.Test.Conn, %{}}
    }

    if remote_ip, do: %{conn | remote_ip: remote_ip}, else: conn
  end

  describe "get/1 with Plug.Conn" do
    test "returns the remote_ip when set (IPv4)" do
      conn = mock_conn(remote_ip: {203, 0, 113, 42})
      assert ClientIP.get(conn) == "203.0.113.42"
    end

    test "returns the remote_ip when set (IPv6)" do
      conn = mock_conn(remote_ip: {8193, 3512, 0, 0, 0, 0, 0, 1})
      assert ClientIP.get(conn) == "2001:db8::1"
    end

    test "falls back to cf-connecting-ip when remote_ip is not a tuple" do
      conn =
        mock_conn(
          headers: [
            {"cf-connecting-ip", "198.51.100.5"},
            {"x-real-ip", "203.0.113.7"},
            {"x-forwarded-for", "203.0.113.9"}
          ]
        )

      assert ClientIP.get(conn) == "198.51.100.5"
    end

    test "falls back to x-real-ip when cf-connecting-ip is absent and remote_ip not set" do
      conn =
        mock_conn(
          headers: [
            {"x-real-ip", "203.0.113.7"},
            {"x-forwarded-for", "203.0.113.9"}
          ]
        )

      assert ClientIP.get(conn) == "203.0.113.7"
    end

    test "falls back to x-forwarded-for when x-real-ip and cf-connecting-ip are absent" do
      conn = mock_conn(headers: [{"x-forwarded-for", "203.0.113.9, 10.0.0.1"}])
      assert ClientIP.get(conn) == "203.0.113.9"
    end

    test "the header fallback skips hops from the right, like the socket path" do
      # The leftmost entry is whatever the client sent; each hop appends the
      # address it heard from. Taking the head would let a visitor pick their
      # own rate-limit key on any deployment that reaches this branch.
      conn = mock_conn(headers: [{"x-forwarded-for", "10.0.0.9, 203.0.113.9"}])
      assert ClientIP.get(conn) == "203.0.113.9"
    end

    test "remote_ip tuple takes precedence over all forwarded headers" do
      conn =
        mock_conn(
          remote_ip: {10, 0, 0, 1},
          headers: [
            {"cf-connecting-ip", "198.51.100.5"},
            {"x-forwarded-for", "203.0.113.9"}
          ]
        )

      assert ClientIP.get(conn) == "10.0.0.1"
    end
  end

  describe "get_user_agent_from_mount/1" do
    test "prefers connect_info :user_agent when available (connected)" do
      socket =
        mock_socket(
          connect_info: %{user_agent: "connect-info-agent"},
          connect_params: %{"headers" => %{"user-agent" => "connect-params-agent"}}
        )

      assert ClientIP.get_user_agent_from_mount(socket) == "connect-info-agent"
    end

    test "falls back to connect_params headers when connect_info has no user agent" do
      socket =
        mock_socket(
          connect_info: %{},
          connect_params: %{"headers" => %{"user-agent" => "connect-params-agent"}}
        )

      assert ClientIP.get_user_agent_from_mount(socket) == "connect-params-agent"
    end

    test "returns unknown when neither connect_info nor connect_params provide a user agent" do
      socket = mock_socket(connect_info: %{}, connect_params: %{})
      assert ClientIP.get_user_agent_from_mount(socket) == "unknown"
    end

    test "returns unknown when user agent is empty string" do
      socket =
        mock_socket(
          connect_info: %{user_agent: ""},
          connect_params: %{"headers" => %{"user-agent" => ""}}
        )

      assert ClientIP.get_user_agent_from_mount(socket) == "unknown"
    end

    test "works during disconnected mount when connect_info is available" do
      socket = mock_socket(connected?: false, connect_info: %{user_agent: "disconnected-agent"})
      assert ClientIP.get_user_agent_from_mount(socket) == "disconnected-agent"
    end
  end

  describe "get_from_mount/1" do
    @peer_data %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}

    test "resolves the client IP from x-real-ip in connect_info x_headers" do
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-real-ip", "203.0.113.7"}, {"x-forwarded-for", "203.0.113.7"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.7"
    end

    test "x-real-ip takes precedence over x-forwarded-for on socket path" do
      # Note: CF-Connecting-IP is NOT available on the socket path — Phoenix's
      # :x_headers only collects headers with an "x-" prefix, so cf-connecting-ip
      # is never present in socket connect_info. Resolution uses x-real-ip first.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [
              {"x-real-ip", "203.0.113.7"},
              {"x-forwarded-for", "203.0.113.9, 10.0.0.1"}
            ]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.7"
    end

    test "resolves x-forwarded-for when x-real-ip is absent" do
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-forwarded-for", "203.0.113.9, 10.0.0.1"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.9"
    end

    test "falls back to the peer address when no forwarded headers are present" do
      socket = mock_socket(connect_info: %{peer_data: @peer_data, x_headers: []})

      assert ClientIP.get_from_mount(socket) == "127.0.0.1"
    end

    test "degrades to the peer address if x_headers arrive as bare strings" do
      # Guards against misconfigured endpoints that store string lists rather than
      # {name, value} tuples — resolution falls through to peer_data rather than
      # crashing or returning a header name.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: ["x-forwarded-for", "x-real-ip"]
          }
        )

      assert ClientIP.get_from_mount(socket) == "127.0.0.1"
    end

    test "handles IPv6 address in x-forwarded-for without truncation" do
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-forwarded-for", "2001:db8::1"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "2001:db8::1"
    end

    test "ignores a private x-real-ip and resolves the visitor from x-forwarded-for" do
      # The shape that broke issue #96: an inner proxy doing the usual
      # `proxy_set_header X-Real-IP $remote_addr` writes the *previous hop's*
      # LAN address. Trusting it keyed every visitor of the deployment to one
      # address, so a booking rate limit meant for one abuser refused everyone.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [
              {"x-real-ip", "192.168.1.254"},
              {"x-forwarded-for", "203.0.113.9, 192.168.1.254"}
            ]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.9"
    end

    test "distinct visitors behind one proxy resolve to distinct addresses" do
      # The property the rate limits actually depend on. Asserting the two
      # differ (rather than each value alone) is what fails if the resolution
      # ever collapses back onto a shared hop.
      addresses =
        for visitor <- ["203.0.113.9", "198.51.100.4"] do
          socket =
            mock_socket(
              connect_info: %{
                peer_data: @peer_data,
                x_headers: [
                  {"x-real-ip", "192.168.1.254"},
                  {"x-forwarded-for", "#{visitor}, 192.168.1.254"}
                ]
              }
            )

          ClientIP.get_from_mount(socket)
        end

      assert addresses == ["203.0.113.9", "198.51.100.4"]
    end

    test "falls back to the peer when every forwarded hop is a private address" do
      # Nothing in the chain names a visitor, so there is no honest answer but
      # the peer. This is what Plug.RemoteIp already does on the conn path.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-forwarded-for", "10.0.0.8, 192.168.1.254"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "127.0.0.1"
    end

    test "a client-supplied x-forwarded-for cannot displace the address the proxy appended" do
      # A visitor who sends their own header puts their value at the head of
      # the chain; the proxy appends the address it actually saw. Reading from
      # the right means the spoofed entry is never the answer.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-forwarded-for", "198.51.100.4, 203.0.113.9"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.9"
    end

    test "takes the last public hop of x-forwarded-for for multi-hop IPv6 chain" do
      # Each hop appends the address it heard from, so the rightmost public
      # entry is the one our own infrastructure wrote. Reading the leftmost
      # instead would let a client name its own address by sending the header.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-forwarded-for", "2001:db8::1, 2001:db8::2"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "2001:db8::2"
    end

    test "strips the port from a bracketed IPv6 hop in x-forwarded-for" do
      # Some proxies emit the bracketed [addr]:port form. The port is fresh per
      # connection, so keeping it would give every request from this client its
      # own rate-limit bucket and the limit would never fire for them.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-forwarded-for", "[2001:db8::1]:8080, 10.0.0.1"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "2001:db8::1"
    end

    test "handles IPv6 in connect_params map fallback" do
      socket =
        mock_socket(
          connect_info: %{peer_data: @peer_data},
          connect_params: %{"headers" => %{"x-forwarded-for" => "2001:db8::1"}}
        )

      assert ClientIP.get_from_mount(socket) == "2001:db8::1"
    end

    test "ignores forwarded headers when peer is a public (untrusted) IP" do
      # A client connecting directly — not through a reverse proxy — must not be
      # able to spoof their IP via x-forwarded-for.
      public_peer = %{address: {203, 0, 113, 50}, port: 12_345, ssl_cert: nil}

      socket =
        mock_socket(
          connect_info: %{
            peer_data: public_peer,
            x_headers: [
              {"x-forwarded-for", "1.2.3.4"},
              {"x-real-ip", "5.6.7.8"}
            ]
          }
        )

      # Should use peer_data directly, ignoring the injected forwarded headers
      assert ClientIP.get_from_mount(socket) == "203.0.113.50"
    end

    test "trusts forwarded headers when peer is RFC-1918 10.x.x.x" do
      private_peer = %{address: {10, 0, 0, 1}, port: 0, ssl_cert: nil}

      socket =
        mock_socket(
          connect_info: %{
            peer_data: private_peer,
            x_headers: [{"x-real-ip", "203.0.113.99"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.99"
    end

    test "trusts forwarded headers when peer is RFC-1918 172.16.x.x" do
      private_peer = %{address: {172, 20, 0, 1}, port: 0, ssl_cert: nil}

      socket =
        mock_socket(
          connect_info: %{
            peer_data: private_peer,
            x_headers: [{"x-real-ip", "203.0.113.99"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.99"
    end
  end

  # Every case above hands `peer_data` a 4-element tuple, which is the one shape
  # production never produces: the endpoint listens dual-stack, so an IPv4
  # reverse proxy arrives IPv4-mapped as `::ffff:172.18.0.1`, an 8-element
  # tuple. While those went unmapped the proxy read as untrusted, the forwarded
  # headers were discarded, and every visitor resolved to the proxy's own
  # address — one shared identity behind every IP-keyed rate limit.
  describe "get_from_mount/1 with an IPv4-mapped peer (dual-stack listener)" do
    @mapped_proxy %{address: {0, 0, 0, 0, 0, 0xFFFF, 0xAC12, 0x0001}, port: 0, ssl_cert: nil}

    test "trusts forwarded headers when the peer is an IPv4-mapped private address" do
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @mapped_proxy,
            x_headers: [{"x-forwarded-for", "203.0.113.99"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.99"
    end

    test "still ignores forwarded headers when the mapped peer is public" do
      # The mapping must not become a way to be trusted: a client connecting
      # directly over a dual-stack socket is as untrusted as over IPv4.
      mapped_public = %{address: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7132}, port: 0, ssl_cert: nil}

      socket =
        mock_socket(
          connect_info: %{
            peer_data: mapped_public,
            x_headers: [{"x-forwarded-for", "1.2.3.4"}, {"x-real-ip", "5.6.7.8"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.50"
    end

    test "reports a mapped peer in plain IPv4 form so both paths share one bucket" do
      # Falling back to the peer must yield the same string `get/1` returns for
      # that client on the conn path, or one visitor occupies two rate-limit
      # buckets depending on whether they arrived over HTTP or the socket.
      mapped_public = %{address: {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7132}, port: 0, ssl_cert: nil}
      socket = mock_socket(connect_info: %{peer_data: mapped_public, x_headers: []})

      assert ClientIP.get_from_mount(socket) == "203.0.113.50"

      assert ClientIP.get_from_mount(socket) ==
               ClientIP.get(mock_conn(remote_ip: {203, 0, 113, 50}))
    end
  end

  # An intranet-only self-host is the one deployment shape where a forwarded
  # address in a private range really does name the visitor. `get_from_mount/2`
  # takes the `:trust_private_client_ips` decision as an argument precisely so
  # both of its states are reachable here; `get_from_mount/1` reads the
  # configured value and is the only production call site.
  describe "get_from_mount/2 and :trust_private_client_ips" do
    # The LAN-facing reverse proxy of an intranet deployment.
    @lan_proxy %{address: {192, 168, 1, 254}, port: 0, ssl_cert: nil}

    defp lan_socket(forwarded_ip) do
      mock_socket(
        connect_info: %{
          peer_data: @lan_proxy,
          x_headers: [{"x-forwarded-for", forwarded_ip}]
        }
      )
    end

    test "enabled: two LAN visitors keep two distinct rate-limit keys" do
      first = ClientIP.get_from_mount(lan_socket("192.168.1.10"), true)
      second = ClientIP.get_from_mount(lan_socket("192.168.1.11"), true)

      assert first == "192.168.1.10"
      assert second == "192.168.1.11"
      refute first == second
      refute first == "192.168.1.254"
    end

    test "enabled: IPv6 unique-local visitors are likewise kept apart" do
      assert ClientIP.get_from_mount(lan_socket("fd00::10"), true) == "fd00::10"
      assert ClientIP.get_from_mount(lan_socket("fd00::11"), true) == "fd00::11"
    end

    test "disabled: the same two visitors collapse onto the proxy peer" do
      first = ClientIP.get_from_mount(lan_socket("192.168.1.10"), false)
      second = ClientIP.get_from_mount(lan_socket("192.168.1.11"), false)

      assert first == "192.168.1.254"
      assert second == "192.168.1.254"
    end

    test "disabled is the compiled-in default" do
      # Guards the default the flag ships with: issue #96 stays fixed for every
      # deployment that does not deliberately opt out.
      socket = lan_socket("192.168.1.10")

      assert ClientIP.get_from_mount(socket) == ClientIP.get_from_mount(socket, false)
      assert ClientIP.get_from_mount(socket) == "192.168.1.254"
    end

    test "the flag never widens peer trust to a public peer" do
      # Enabling it must not make a directly-connected visitor's own forwarded
      # header authoritative; that would let anyone choose their own bucket.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: %{address: {203, 0, 113, 50}, port: 0, ssl_cert: nil},
            x_headers: [{"x-forwarded-for", "192.168.1.10"}]
          }
        )

      assert ClientIP.get_from_mount(socket, true) == "203.0.113.50"
    end

    test "public visitors resolve identically in both states" do
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @lan_proxy,
            x_headers: [{"x-forwarded-for", "203.0.113.9"}]
          }
        )

      assert ClientIP.get_from_mount(socket, true) == "203.0.113.9"
      assert ClientIP.get_from_mount(socket, false) == "203.0.113.9"
    end
  end

  # The conn path's half of the same rule. The endpoint's `RemoteIp` plug takes
  # its `clients:` list from `ClientIP.remote_ip_clients/0`. These pin *which*
  # option does it: `proxies:` cannot, because `RemoteIp.type/2` consults its
  # own hardcoded `@reserved` list, already holding exactly these blocks, only
  # after both, so listing them as proxies changes nothing. Only `clients:`
  # outranks `@reserved`. That the endpoint really passes these options is
  # pinned by `TymeslotWeb.EndpointRemoteIpTest`.
  describe "conn-path agreement through RemoteIp" do
    @private_blocks ClientIP.remote_ip_clients(true)
    @headers_opt [headers: ~w[x-forwarded-for x-real-ip]]

    test "the clients list is empty unless the flag is enabled" do
      assert ClientIP.remote_ip_clients(false) == []
      assert ClientIP.remote_ip_clients() == []
    end

    test "only clients: re-admits a private forwarded address" do
      headers = [{"x-forwarded-for", "192.168.1.10"}]

      assert RemoteIp.from(headers, @headers_opt ++ [clients: @private_blocks]) ==
               {192, 168, 1, 10}

      assert RemoteIp.from(headers, @headers_opt ++ [proxies: @private_blocks]) == nil
      assert RemoteIp.from(headers, @headers_opt) == nil
    end

    test "both paths resolve a multi-hop private chain to the same address" do
      # Two LAN visitors' worth of chain: the rightmost entry is the one either
      # path may name, and enabling the flag has to move both of them or neither.
      headers = [{"x-forwarded-for", "192.168.1.10, 192.168.1.11"}]

      socket =
        mock_socket(
          connect_info: %{
            peer_data: %{address: {192, 168, 1, 254}, port: 0, ssl_cert: nil},
            x_headers: headers
          }
        )

      enabled =
        headers
        |> RemoteIp.from(@headers_opt ++ [clients: @private_blocks])
        |> :inet.ntoa()
        |> to_string()

      assert enabled == "192.168.1.11"
      assert enabled == ClientIP.get_from_mount(socket, true)

      # Disabled, RemoteIp finds no client at all and the plug leaves
      # conn.remote_ip as the peer, which is what the socket path falls back to.
      assert RemoteIp.from(headers, @headers_opt) == nil
      assert ClientIP.get_from_mount(socket, false) == "192.168.1.254"
    end
  end
end
