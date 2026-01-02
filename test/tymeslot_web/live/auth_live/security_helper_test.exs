defmodule TymeslotWeb.AuthLive.SecurityHelperTest do
  use ExUnit.Case, async: true

  alias TymeslotWeb.AuthLive.SecurityHelper

  test "validate_csrf_token/2 returns invalid_csrf when token is missing" do
    socket =
      %Phoenix.LiveView.Socket{
        assigns: %{
          csrf_token: "expected",
          client_ip: "127.0.0.1",
          user_agent: "test-agent"
        }
      }

    assert {:error, :invalid_csrf} = SecurityHelper.validate_csrf_token(socket, %{})
  end

  test "validate_csrf_token/2 returns invalid_csrf when token is non-binary" do
    socket =
      %Phoenix.LiveView.Socket{
        assigns: %{
          csrf_token: "expected",
          client_ip: "127.0.0.1",
          user_agent: "test-agent"
        }
      }

    assert {:error, :invalid_csrf} =
             SecurityHelper.validate_csrf_token(socket, %{"_csrf_token" => 123})
  end
end
