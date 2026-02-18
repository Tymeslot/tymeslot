defmodule TymeslotWeb.MeetingManagement.SharedHelpersTest do
  use TymeslotWeb.ConnCase, async: true
  @moduletag :utils

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Phoenix.LiveView.Socket
  alias Tymeslot.Repo
  alias TymeslotWeb.MeetingManagement.SharedHelpers

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, booking_theme: "2")
    meeting = insert(:meeting, organizer_user: user, status: "confirmed")

    # We need a socket for some tests
    socket = %Socket{}

    {:ok, meeting: meeting, user: user, profile: profile, socket: socket}
  end

  describe "validate_meeting_access/2" do
    test "returns :ok when meeting exists and policy check passes", %{meeting: meeting} do
      assert {:ok, validated_meeting} = SharedHelpers.validate_meeting_access(meeting.uid, :view)
      assert validated_meeting.id == meeting.id
    end

    test "returns error when meeting not found" do
      assert {:error, "Meeting not found", "/"} =
               SharedHelpers.validate_meeting_access("non-existent", :view)
    end

    test "returns error when policy check fails (cancelled meeting)", %{meeting: meeting} do
      cancelled_meeting = meeting |> Changeset.change(status: "cancelled") |> Repo.update!()

      assert {:error, "Meeting is already cancelled", "/"} =
               SharedHelpers.validate_meeting_access(cancelled_meeting.uid, :cancel)
    end

    test "returns :ok for valid cancellation", %{meeting: meeting} do
      future_meeting = setup_future_meeting(meeting)
      assert {:ok, _result} = SharedHelpers.validate_meeting_access(future_meeting.uid, :cancel)
    end

    test "returns :ok for valid rescheduling", %{meeting: meeting} do
      future_meeting = setup_future_meeting(meeting)

      assert {:ok, _result} =
               SharedHelpers.validate_meeting_access(future_meeting.uid, :reschedule)
    end
  end

  defp setup_future_meeting(meeting) do
    meeting
    |> Changeset.change(
      start_time: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second),
      end_time: DateTime.utc_now() |> DateTime.add(7200) |> DateTime.truncate(:second)
    )
    |> Repo.update!()
  end

  describe "validate_meeting_access_with_theme/2" do
    test "returns meeting, profile and theme info when valid", %{
      meeting: meeting,
      profile: profile
    } do
      assert {:ok, validated_meeting, validated_profile, theme_info} =
               SharedHelpers.validate_meeting_access_with_theme(meeting.uid, :view)

      assert validated_meeting.id == meeting.id
      assert validated_profile.id == profile.id
      assert theme_info.theme_id == "2"
    end

    test "returns error when meeting not found" do
      assert {:error, "Meeting not found", "/"} =
               SharedHelpers.validate_meeting_access_with_theme("non-existent", :view)
    end

    test "returns error when policy check fails", %{meeting: meeting} do
      cancelled_meeting = meeting |> Changeset.change(status: "cancelled") |> Repo.update!()

      assert {:error, "Cannot reschedule a cancelled meeting", "/"} =
               SharedHelpers.validate_meeting_access_with_theme(
                 cancelled_meeting.uid,
                 :reschedule
               )
    end

    test "returns default theme info when organizer has no profile", %{meeting: _meeting} do
      # Create a meeting with no organizer_user_id and no organizer_email that matches a user
      meeting_no_org =
        insert(:meeting, organizer_user_id: nil, organizer_email: "unknown@example.com")

      assert {:ok, _meeting, nil, theme_info} =
               SharedHelpers.validate_meeting_access_with_theme(meeting_no_org.uid, :view)

      assert theme_info.theme_id == "1"
      assert theme_info.theme_customization == nil
    end
  end

  describe "handle_validation_result/3" do
    test "assigns meeting to socket on success", %{meeting: meeting, socket: socket} do
      {:ok, updated_socket} = SharedHelpers.handle_validation_result(socket, {:ok, meeting})
      assert updated_socket.assigns.meeting == meeting
    end

    test "merges extra assigns on success", %{meeting: meeting, socket: socket} do
      {:ok, updated_socket} =
        SharedHelpers.handle_validation_result(socket, {:ok, meeting}, %{foo: :bar})

      assert updated_socket.assigns.meeting == meeting
      assert updated_socket.assigns.foo == :bar
    end
  end

  describe "handle_validation_result_with_theme/3" do
    test "assigns meeting and theme info to socket on success", %{
      meeting: meeting,
      profile: profile,
      socket: socket
    } do
      theme_info = %{theme_id: "2", theme_customization: nil}

      {:ok, updated_socket} =
        SharedHelpers.handle_validation_result_with_theme(
          socket,
          {:ok, meeting, profile, theme_info}
        )

      assert updated_socket.assigns.meeting == meeting
      assert updated_socket.assigns.organizer_profile == profile
      assert updated_socket.assigns.theme_id == "2"
    end
  end
end
