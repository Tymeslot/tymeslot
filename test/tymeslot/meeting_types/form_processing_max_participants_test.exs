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
        "is_active" => "true"
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
end
