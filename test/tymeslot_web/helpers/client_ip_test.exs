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

    test "falls back to x-forwarded-for first hop when x-real-ip and cf-connecting-ip are absent" do
      conn = mock_conn(headers: [{"x-forwarded-for", "203.0.113.9, 10.0.0.1"}])
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

    test "falls back to x-real-ip when cf-connecting-ip is absent" do
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-real-ip", "203.0.113.7"}, {"x-forwarded-for", "203.0.113.9"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "203.0.113.7"
    end

    test "takes the first hop of x-forwarded-for when x-real-ip is absent" do
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

    test "takes the first hop of x-forwarded-for for multi-hop IPv6 chain" do
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-forwarded-for", "2001:db8::1, 2001:db8::2"}]
          }
        )

      assert ClientIP.get_from_mount(socket) == "2001:db8::1"
    end

    test "handles bracketed IPv6 address in x-forwarded-for" do
      # Some proxies emit the bracketed form [addr]:port in x-forwarded-for;
      # we extract the first comma-delimited hop and return it as-is without
      # stripping the brackets — the raw string is used for fingerprinting, not
      # parsed as an IP, so bracket preservation is safer than a fragile strip.
      socket =
        mock_socket(
          connect_info: %{
            peer_data: @peer_data,
            x_headers: [{"x-forwarded-for", "[2001:db8::1]:8080, 10.0.0.1"}]
          }
        )

      # First comma-split token after trim is "[2001:db8::1]:8080"
      assert ClientIP.get_from_mount(socket) == "[2001:db8::1]:8080"
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
end
