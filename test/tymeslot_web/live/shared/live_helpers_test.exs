defmodule TymeslotWeb.Live.Shared.LiveHelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Live.Shared.LiveHelpers

  # Mock socket for testing
  defp mock_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, assigns)
    }
  end

  describe "ok/1 and noreply/1" do
    test "return correct tuples" do
      socket = mock_socket()
      assert LiveHelpers.ok(socket) == {:ok, socket}
      assert LiveHelpers.noreply(socket) == {:noreply, socket}
    end
  end
end
