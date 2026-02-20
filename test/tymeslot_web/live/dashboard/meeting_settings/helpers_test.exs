defmodule TymeslotWeb.Dashboard.MeetingSettings.HelpersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :meeting_types

  alias Ecto.Changeset
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

  describe "handle_meeting_type_save_result/2" do
    test "handles video_integration_required error" do
      socket = mock_socket()

      {:noreply, socket} =
        Helpers.handle_meeting_type_save_result({:error, :video_integration_required}, socket)

      assert_receive {:flash, {:error, _}}
      assert hd(socket.assigns.form_errors[:video_integration]) =~ "select a video provider"
      refute socket.assigns.saving
    end

    test "handles invalid_duration error" do
      socket = mock_socket()

      {:noreply, socket} =
        Helpers.handle_meeting_type_save_result({:error, :invalid_duration}, socket)

      assert_receive {:flash, {:error, "Duration must be a valid number"}}
      assert is_list(socket.assigns.form_errors[:duration])
      refute socket.assigns.saving
    end

    test "handles changeset errors" do
      changeset =
        {%{}, %{name: :string}}
        |> Changeset.cast(%{}, [:name])
        |> Changeset.validate_required([:name])

      socket = mock_socket()
      {:noreply, socket} = Helpers.handle_meeting_type_save_result({:error, changeset}, socket)

      assert is_list(socket.assigns.form_errors[:name])
      refute socket.assigns.saving
    end

    test "handles unknown errors" do
      socket = mock_socket()

      {:noreply, socket} =
        Helpers.handle_meeting_type_save_result({:error, :something_unexpected}, socket)

      assert_receive {:flash, {:error, "Failed to save meeting type"}}
      assert is_list(socket.assigns.form_errors[:base])
      refute socket.assigns.saving
    end
  end
end
