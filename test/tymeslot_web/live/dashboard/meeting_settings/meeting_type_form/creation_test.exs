defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.CreationTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :meeting_types

  alias Ecto.Changeset
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.Creation

  defp mock_socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, form_errors: %{}, is_edit: false}, assigns)
    }
  end

  describe "apply_result/2 on failure" do
    test "routes form validation errors to the fields, without a flash" do
      socket =
        Creation.apply_result({:error, {:invalid_form, %{name: ["is required"]}}}, mock_socket())

      assert socket.assigns.form_errors == %{name: ["is required"]}
      refute socket.assigns.is_edit
      refute_received {:flash, _}
    end

    test "routes changeset errors to the fields" do
      changeset =
        {%{}, %{name: :string}}
        |> Changeset.cast(%{}, [:name])
        |> Changeset.validate_required([:name])

      socket = Creation.apply_result({:error, changeset}, mock_socket())

      assert socket.assigns.form_errors[:name] == ["can't be blank"]
      refute socket.assigns.is_edit
    end

    test "flashes and marks the field for video_integration_required" do
      socket = Creation.apply_result({:error, :video_integration_required}, mock_socket())

      assert_receive {:flash, {:error, _message}}
      assert hd(socket.assigns.form_errors[:video_integration]) =~ "select a video provider"
    end

    test "flashes and marks the field for invalid_duration" do
      socket = Creation.apply_result({:error, :invalid_duration}, mock_socket())

      assert_receive {:flash, {:error, "Duration must be a valid number"}}
      assert socket.assigns.form_errors[:duration] == ["Duration must be a valid number"]
    end

    test "flashes the plan message for a gated feature without marking a field" do
      socket = Creation.apply_result({:error, :insufficient_plan}, mock_socket())

      assert_receive {:flash, {:error, "Custom booking questions are available on Pro plans."}}
      assert socket.assigns.form_errors == %{}
    end

    test "flashes a generic failure for unknown errors" do
      socket = Creation.apply_result({:error, :something_unexpected}, mock_socket())

      assert_receive {:flash, {:error, "Failed to save meeting type"}}
      assert socket.assigns.form_errors[:base] == ["Something unexpected"]
    end
  end
end
