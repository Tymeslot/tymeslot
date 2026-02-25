defmodule Tymeslot.MeetingTypes.FormProcessingTest do
  @moduledoc """
  Tests for form-based meeting type creation and updates.
  Focuses on validation of video integrations, calendar integrations,
  CalDAV paths, reminder configs, and other form-specific logic.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes

  # =====================================
  # Creating Meeting Types from Form
  # =====================================

  describe "when creating meeting type from form" do
    test "creates in-person meeting type" do
      user = insert(:user)

      form_params = %{
        "name" => "Consultation",
        "duration" => "60",
        "description" => "One hour consultation",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.name == "Consultation"
      assert meeting_type.duration_minutes == 60
      assert meeting_type.allow_video == false
    end

    test "fails when video mode selected but no video integration" do
      user = insert(:user)

      form_params = %{
        "name" => "Video Call",
        "duration" => "30",
        "description" => "Video meeting",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "video",
        selected_icon: "hero-phone",
        selected_video_integration_id: nil
      }

      result = MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert {:error, :video_integration_required} = result
    end

    test "creates video meeting type with valid video integration" do
      user = insert(:user)
      video_integration = insert(:video_integration, user: user, is_active: true)

      form_params = %{
        "name" => "Video Consultation",
        "duration" => "45",
        "description" => "Video consultation session",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "video",
        selected_icon: "hero-phone",
        selected_video_integration_id: video_integration.id
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.name == "Video Consultation"
      assert meeting_type.allow_video == true
      assert meeting_type.video_integration_id == video_integration.id
    end

    test "fails when calendar integration does not belong to user" do
      user = insert(:user)
      other_user = insert(:user)

      other_calendar = insert(:calendar_integration, user: other_user)

      form_params = %{
        "name" => "Calendar Meeting",
        "duration" => "30",
        "description" => "Calendar scoped meeting",
        "is_active" => "true",
        "calendar_integration_id" => other_calendar.id,
        "target_calendar_id" => "cal-1"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:error, :calendar_integration_invalid} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
    end

    test "fails when target calendar is not in the integration calendar list" do
      user = insert(:user)

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          calendar_list: [%{"id" => "cal-1", "name" => "Primary", "selected" => true}]
        )

      form_params = %{
        "name" => "Calendar Meeting",
        "duration" => "30",
        "description" => "Calendar scoped meeting",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => "cal-2"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:error, :target_calendar_invalid} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
    end

    test "fails when reminder config is invalid" do
      user = insert(:user)

      form_params = %{
        "name" => "Reminder Test",
        "duration" => "30",
        "description" => "Invalid reminder config",
        "is_active" => "true",
        "reminder_config" => [
          %{"value" => "10", "unit" => "weeks"}
        ]
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:error, :invalid_reminder_config} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
    end

    test "successfully creates with CalDAV calendar containing @ symbol and slashes" do
      user = insert(:user)

      # CalDAV paths often contain @ symbols (email) and slashes
      caldav_path = "/dav/#{user.email}/Calendar/"

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_list: [
            %{
              "id" => caldav_path,
              "name" => "Calendar",
              "selected" => true
            }
          ]
        )

      form_params = %{
        "name" => "CalDAV Meeting",
        "duration" => "30",
        "description" => "Meeting with CalDAV calendar",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => caldav_path
      }

      ui_state = %{
        meeting_mode: "personal",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      # Verify CalDAV path is preserved exactly
      assert meeting_type.target_calendar_id == caldav_path
      assert meeting_type.calendar_integration_id == calendar_integration.id
    end

    test "successfully creates with Nextcloud CalDAV path format" do
      user = insert(:user)

      # Nextcloud uses a different path format
      nextcloud_path = "/remote.php/dav/calendars/#{user.email}/personal/"

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_list: [
            %{
              "id" => nextcloud_path,
              "name" => "Personal",
              "selected" => true
            }
          ]
        )

      form_params = %{
        "name" => "Nextcloud Meeting",
        "duration" => "45",
        "description" => "Meeting with Nextcloud calendar",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => nextcloud_path
      }

      ui_state = %{
        meeting_mode: "personal",
        selected_icon: "hero-bolt",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.target_calendar_id == nextcloud_path
    end

    test "validates target calendar when ID is percent-encoded in calendar_list" do
      user = insert(:user)

      # Zimbra-style: server returns percent-encoded href
      encoded_id = "/dav/user%40example.org/Calendar"

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_list: [
            %{"id" => encoded_id, "name" => "Calendar", "selected" => true}
          ]
        )

      form_params = %{
        "name" => "Zimbra Meeting",
        "duration" => "30",
        "description" => "Test percent-encoded calendar ID",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => encoded_id
      }

      ui_state = %{
        meeting_mode: "personal",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)

      assert meeting_type.target_calendar_id == encoded_id
    end

    test "validates target calendar when encoding differs between stored ID and target" do
      user = insert(:user)

      # calendar_list stores encoded form, target uses decoded form
      encoded_id = "/dav/user%40example.org/Calendar"
      decoded_id = "/dav/user@example.org/Calendar"

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_list: [
            %{"id" => encoded_id, "name" => "Calendar", "selected" => true}
          ]
        )

      form_params = %{
        "name" => "Encoding Mismatch Meeting",
        "duration" => "30",
        "description" => "Target uses decoded form",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => decoded_id
      }

      ui_state = %{
        meeting_mode: "personal",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, _meeting_type} =
               MeetingTypes.create_meeting_type_from_form(user.id, form_params, ui_state)
    end
  end

  # =====================================
  # Updating Meeting Types from Form
  # =====================================

  describe "when updating meeting type from form" do
    test "successfully updates with form parameters" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      form_params = %{
        "name" => "Updated Meeting",
        "duration" => "90",
        "description" => "Updated description",
        "is_active" => "true"
      }

      ui_state = %{
        meeting_mode: "in_person",
        selected_icon: "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(meeting_type, form_params, ui_state)

      assert updated.name == "Updated Meeting"
      assert updated.duration_minutes == 90
    end

    test "successfully updates to use CalDAV calendar" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, calendar_integration_id: nil)

      caldav_path = "/dav/#{user.email}/Calendar/"

      calendar_integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_list: [
            %{
              "id" => caldav_path,
              "name" => "Calendar",
              "selected" => true
            }
          ]
        )

      form_params = %{
        "name" => meeting_type.name,
        "duration" => to_string(meeting_type.duration_minutes),
        "description" => meeting_type.description || "",
        "is_active" => "true",
        "calendar_integration_id" => calendar_integration.id,
        "target_calendar_id" => caldav_path
      }

      ui_state = %{
        meeting_mode: "personal",
        selected_icon: meeting_type.icon || "hero-clock",
        selected_video_integration_id: nil
      }

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type_from_form(meeting_type, form_params, ui_state)

      assert updated.calendar_integration_id == calendar_integration.id
      assert updated.target_calendar_id == caldav_path
    end
  end
end
