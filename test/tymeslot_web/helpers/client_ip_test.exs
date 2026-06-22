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
      # Guards against the legacy {:x_headers, [...]} static-injection shape:
      # no tuple matches, so resolution falls through to peer_data rather than
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
  end
end
