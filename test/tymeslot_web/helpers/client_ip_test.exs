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
end
