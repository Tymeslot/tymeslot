defmodule TymeslotWeb.Live.Shared.LiveHelpersTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  alias Tymeslot.DatabaseQueries.UserSessionQueries
  alias Tymeslot.Security.Token
  alias Tymeslot.TestFixtures
  alias TymeslotWeb.Live.Shared.LiveHelpers

  # Mock socket for testing
  @moduletag :utils
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

  describe "assign_user_timezone/2" do
    test "assigns from params" do
      socket = mock_socket()
      socket = LiveHelpers.assign_user_timezone(socket, %{"timezone" => "America/New_York"})
      assert socket.assigns.user_timezone == "America/New_York"
    end

    # Skipping the default test because it calls get_connect_params which is hard to mock in unit tests
  end

  describe "setup_form_state/2" do
    test "sets up initial assigns" do
      socket = mock_socket()
      socket = LiveHelpers.setup_form_state(socket, %{"name" => "test"})
      assert socket.assigns.form.params["name"] == "test"
      assert socket.assigns.touched_fields == MapSet.new()
      assert socket.assigns.validation_errors == []
      refute socket.assigns.submitting
    end
  end

  describe "mark_field_touched/2" do
    test "adds field to touched_fields" do
      socket = mock_socket(%{touched_fields: MapSet.new()})
      socket = LiveHelpers.mark_field_touched(socket, :email)
      assert MapSet.member?(socket.assigns.touched_fields, :email)
    end

    test "handles string field names" do
      socket = mock_socket(%{touched_fields: MapSet.new()})
      # Use an existing atom
      socket = LiveHelpers.mark_field_touched(socket, "email")
      assert MapSet.member?(socket.assigns.touched_fields, :email)
    end
  end

  describe "ok/1 and noreply/1" do
    test "return correct tuples" do
      socket = mock_socket()
      assert LiveHelpers.ok(socket) == {:ok, socket}
      assert LiveHelpers.noreply(socket) == {:noreply, socket}
    end
  end

  describe "with_submission_state/2" do
    test "handles successful submission" do
      socket = mock_socket()
      {:ok, socket, result} = LiveHelpers.with_submission_state(socket, fn -> {:ok, :success} end)
      assert result == :success
      refute socket.assigns.submitting
    end

    test "handles failed submission" do
      socket = mock_socket()

      {:error, socket, reason} =
        LiveHelpers.with_submission_state(socket, fn -> {:error, :fail} end)

      assert reason == :fail
      refute socket.assigns.submitting
    end
  end
end
