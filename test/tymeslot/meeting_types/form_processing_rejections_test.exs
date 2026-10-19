defmodule Tymeslot.MeetingTypes.FormProcessingRejectionsTest do
  @moduledoc """
  Form submissions that must be refused outright: another user's video
  integration and a malformed reminder config.
  """

  use Tymeslot.DataCase, async: false
  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes

  # =====================================
  # Cross-user Video Integration
  # =====================================

  describe "video integration cross-user isolation" do
    test "rejects video integration belonging to another user" do
      user_a = insert(:user)
      user_b = insert(:user)
      video_integration = insert(:video_integration, user: user_a, is_active: true)

      form_params = %{
        "name" => "Cross-User Video",
        "duration" => "30",
        "description" => "Should fail",
        "is_active" => "true",
        "locations" => [
          %{
            "kind" => "video",
            "label" => "Zoom",
            "video_integration_ids" => [to_string(video_integration.id)],
            "position" => "0"
          }
        ]
      }

      assert {:error, :invalid_video_integration} =
               MeetingTypes.create_meeting_type_from_form(user_b.id, form_params, %{
                 selected_icon: "hero-phone"
               })
    end
  end

  # =====================================
  # Malformed Reminder Config
  # =====================================

  describe "malformed reminder config" do
    test "rejects malformed JSON reminder config" do
      user = insert(:user)

      form_params = %{
        "name" => "Broken Reminder",
        "duration" => "30",
        "description" => "Malformed reminder JSON",
        "is_active" => "true",
        "reminder_config" => "{broken"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:error, :invalid_reminder_config} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
    end
  end
end
