defmodule Tymeslot.MeetingTypes.FormProcessingMaxParticipantsTest do
  @moduledoc """
  Tests for the max_participants param mapping in meeting type form
  processing. Kept in its own module, mirroring the allow_guests split, to
  stay under the project line-count limit.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :meeting_types

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingTypes

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true
    )
  end

  defp ui_state do
    %{
      meeting_mode: "in_person",
      selected_icon: "hero-clock",
      selected_video_integration_id: nil
    }
  end

  defp form_params(overrides) do
    Map.merge(
      %{
        "name" => "Group Workshop",
        "duration" => "60",
        "description" => "",
        "is_active" => "true",
        # A group type's location is fixed in advance; "custom" always is.
        "locations" => [%{"kind" => "custom", "label" => "Main hall", "details" => "Room 1"}]
      },
      overrides
    )
  end

  describe "max_participants param mapping" do
    test "persists the parsed limit" do
      user = insert(:user)

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 form_params(%{"max_participants" => "12"}),
                 ui_state()
               )

      assert meeting_type.max_participants == 12
    end

    test "defaults to 1 when the param is absent" do
      user = insert(:user)

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params(%{}), ui_state())

      assert meeting_type.max_participants == 1
    end

    test "defaults to 1 when the param is blank" do
      user = insert(:user)

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 form_params(%{"max_participants" => ""}),
                 ui_state()
               )

      assert meeting_type.max_participants == 1
    end

    test "rejects a non-numeric limit" do
      user = insert(:user)

      assert {:error, :invalid_max_participants} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 form_params(%{"max_participants" => "abc"}),
                 ui_state()
               )
    end

    test "an out-of-range limit surfaces the schema error" do
      user = insert(:user)

      assert {:error, %Ecto.Changeset{} = changeset} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 form_params(%{"max_participants" => "1000"}),
                 ui_state()
               )

      assert "must be less than or equal to 999" in errors_on(changeset).max_participants
    end

    test "updating a meeting type changes the limit" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      params =
        form_params(%{
          "name" => meeting_type.name,
          "duration" => to_string(meeting_type.duration_minutes),
          "description" => meeting_type.description || "",
          "max_participants" => "25"
        })

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(meeting_type, params, ui_state())

      assert updated.max_participants == 25
    end
  end

  describe "group bookings plan gate" do
    defmodule DenyGroupBookingsChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :group_bookings_allowed), do: {:error, :insufficient_plan}
      def check_access(_user_id, _feature), do: :ok
    end

    defmodule FailingChecker do
      @behaviour Tymeslot.Features.CheckerBehaviour
      @impl Tymeslot.Features.CheckerBehaviour
      def check_access(_user_id, :group_bookings_allowed), do: raise("checker down")
      def check_access(_user_id, _feature), do: :ok
    end

    setup do
      setup_config(:tymeslot, feature_access_checker: DenyGroupBookingsChecker)
    end

    defp group_type(user, limit) do
      insert(:meeting_type,
        user: user,
        max_participants: limit,
        locations: [in_person_location([insert(:venue, user: user)])]
      )
    end

    defp edit_params(meeting_type, overrides) do
      form_params(
        Map.merge(
          %{
            "name" => meeting_type.name,
            "duration" => to_string(meeting_type.duration_minutes),
            "description" => meeting_type.description || ""
          },
          overrides
        )
      )
    end

    test "Core's default checker allows group bookings" do
      setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
      user = insert(:user)

      assert {:ok, %{max_participants: 5}} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 form_params(%{"max_participants" => "5"}),
                 ui_state()
               )
    end

    test "creating a group type without access is refused" do
      user = insert(:user)

      assert {:error, :group_bookings_not_allowed} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 form_params(%{"max_participants" => "5"}),
                 ui_state()
               )

      refute Enum.any?(
               MeetingTypes.get_all_meeting_types(user.id),
               &(&1.name == "Group Workshop")
             )
    end

    test "creating a one-to-one type without access is allowed" do
      user = insert(:user)

      assert {:ok, %{max_participants: 1}} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 form_params(%{"max_participants" => "1"}),
                 ui_state()
               )
    end

    test "turning a one-to-one type into a group type without access is refused" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      assert {:error, :group_bookings_not_allowed} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 edit_params(meeting_type, %{"max_participants" => "5"}),
                 ui_state()
               )

      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).max_participants == 1
    end

    test "raising an existing group type's limit without access is refused" do
      user = insert(:user)
      meeting_type = group_type(user, 4)

      assert {:error, :group_bookings_not_allowed} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 edit_params(meeting_type, %{"max_participants" => "5"}),
                 ui_state()
               )
    end

    test "an existing group type can still be saved, and its limit lowered, without access" do
      user = insert(:user)
      meeting_type = group_type(user, 4)

      assert {:ok, renamed} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 edit_params(meeting_type, %{"name" => "Renamed", "max_participants" => "4"}),
                 ui_state()
               )

      assert %{name: "Renamed", max_participants: 4} = renamed

      assert {:ok, %{max_participants: 3}} =
               MeetingTypes.update_meeting_type_from_form(
                 renamed,
                 edit_params(renamed, %{"max_participants" => "3"}),
                 ui_state()
               )
    end

    test "turning group bookings off without access is allowed" do
      user = insert(:user)
      meeting_type = group_type(user, 4)

      assert {:ok, %{max_participants: 1}} =
               MeetingTypes.update_meeting_type_from_form(
                 meeting_type,
                 edit_params(meeting_type, %{"max_participants" => "1"}),
                 ui_state()
               )
    end

    test "a failing checker refuses enabling with its own reason" do
      setup_config(:tymeslot, feature_access_checker: FailingChecker)
      user = insert(:user)

      assert {:error, :feature_access_checker_failed} =
               MeetingTypes.create_meeting_type_from_form(
                 user.id,
                 form_params(%{"max_participants" => "5"}),
                 ui_state()
               )
    end
  end
end
