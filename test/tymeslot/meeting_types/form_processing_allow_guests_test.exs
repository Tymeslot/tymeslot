defmodule Tymeslot.MeetingTypes.FormProcessingAllowGuestsTest do
  @moduledoc """
  Tests for the allow_guests param mapping in meeting type form processing.
  Extracted from FormProcessingTest to keep individual modules under the
  project line-count limit.
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

  describe "allow_guests param mapping" do
    test "persists allow_guests: true when param is \"true\"" do
      user = insert(:user)

      form_params = %{
        "name" => "Guest-friendly Call",
        "duration" => "30",
        "description" => "",
        "is_active" => "true",
        "allow_guests" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.allow_guests == true
    end

    test "persists allow_guests: false when param is absent" do
      user = insert(:user)

      form_params = %{
        "name" => "No Guests Call",
        "duration" => "30",
        "description" => "",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.allow_guests == false
    end

    test "persists allow_guests: false when param is \"false\"" do
      user = insert(:user)

      form_params = %{
        "name" => "No Guests Either",
        "duration" => "30",
        "description" => "",
        "is_active" => "true",
        "allow_guests" => "false"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.allow_guests == false
    end

    test "updating a meeting type toggles allow_guests from false to true" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, allow_guests: false)

      form_params = %{
        "name" => meeting_type.name,
        "duration" => to_string(meeting_type.duration_minutes),
        "description" => meeting_type.description || "",
        "is_active" => "true",
        "allow_guests" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: meeting_type.icon || "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(meeting_type, form_params, ui_state)

      assert updated.allow_guests == true
    end

    test "updating a meeting type toggles allow_guests from true to false" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, allow_guests: true)

      form_params = %{
        "name" => meeting_type.name,
        "duration" => to_string(meeting_type.duration_minutes),
        "description" => meeting_type.description || "",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: meeting_type.icon || "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(meeting_type, form_params, ui_state)

      assert updated.allow_guests == false
    end
  end
end
