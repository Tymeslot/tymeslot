defmodule TymeslotWeb.Live.Shared.LiveHelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Tymeslot.Auth.UserSessionQueries
  alias Tymeslot.Security.Token
  alias Tymeslot.TestFixtures
  alias TymeslotWeb.Live.Shared.LiveHelpers

  # Mock socket for testing
  defp mock_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns)
    }
  end

  describe "assign_current_user/2" do
    test "assigns user if token exists" do
      user = TestFixtures.create_user_fixture()
      token = Token.generate_session_token()
      expires_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 24, :hour), :second)

      # We need to insert the token into the database for Authentication.get_user_by_session_token to work
      UserSessionQueries.create_session(user.id, token, expires_at)

      socket = mock_socket()
      socket = LiveHelpers.assign_current_user(socket, %{"user_token" => token})
      assert socket.assigns.current_user.id == user.id
    end

    test "assigns nil if no token" do
      socket = mock_socket()
      socket = LiveHelpers.assign_current_user(socket, %{})
      assert socket.assigns.current_user == nil
    end
  end

  describe "ok/1 and noreply/1" do
    test "return correct tuples" do
      socket = mock_socket()
      assert LiveHelpers.ok(socket) == {:ok, socket}
      assert LiveHelpers.noreply(socket) == {:noreply, socket}
    end
  end
end
