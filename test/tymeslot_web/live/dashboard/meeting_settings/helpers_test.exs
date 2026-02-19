defmodule TymeslotWeb.Dashboard.MeetingSettings.HelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :meeting_types

  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  defp mock_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, touched_fields: MapSet.new()}, assigns)
    }
  end

  describe "reset_form_state/1" do
    test "resets all form-related assigns" do
      socket = mock_socket(%{show_add_form: true, saving: true})
      socket = Helpers.reset_form_state(socket)
      refute socket.assigns.show_add_form
      refute socket.assigns.saving
      assert socket.assigns.form_errors == %{}
    end
  end

  describe "format_errors/1" do
    test "formats list of errors" do
      assert Helpers.format_errors(["error 1", "error 2"]) == "error 1, error 2"
    end

    test "formats single string error" do
      assert Helpers.format_errors("single error") == "single error"
    end

    test "handles other types" do
      assert Helpers.format_errors(nil) == "An error occurred"
    end
  end
end
