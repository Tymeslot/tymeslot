defmodule TymeslotWeb.Dashboard.MeetingSettings.HelpersTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers

  defp mock_socket(assigns \\ %{}) do
  @moduletag :utils
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

  describe "handle_meeting_type_save_result/2" do
    test "handles success" do
      socket = mock_socket(%{editing_type: nil})
      {:noreply, socket} = Helpers.handle_meeting_type_save_result({:ok, %{}}, socket)
      assert_receive {:meeting_type_changed}
      assert_receive {:flash, {:info, "Meeting type created"}}
      refute socket.assigns.show_add_form
    end

    test "handles specific errors" do
      socket = mock_socket()

      {:noreply, socket} =
        Helpers.handle_meeting_type_save_result({:error, :video_integration_required}, socket)

      assert hd(socket.assigns.form_errors[:video_integration]) =~ "select a video provider"
      refute socket.assigns.saving
    end
  end
end
