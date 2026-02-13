defmodule Tymeslot.MeetingTypesContextTest do
  @moduledoc """
  Comprehensive behavior tests for the MeetingTypes context module.
  Focuses on user-facing functionality and business rules.
  """

  use Tymeslot.DataCase, async: true

  alias Tymeslot.MeetingTypes

  # =====================================
  # Retrieving Meeting Types Behaviors
  # =====================================

  describe "when user views their meeting types" do
    test "returns all active meeting types" do
      user = insert(:user)
      active_type = insert(:meeting_type, user: user, is_active: true)
      _inactive_type = insert(:meeting_type, user: user, is_active: false)

      result = MeetingTypes.get_active_meeting_types(user.id)

      assert length(result) == 1
      assert hd(result).id == active_type.id
    end

    test "creates default meeting types if user has none" do
      user = insert(:user)

      # User has no meeting types initially
      result = MeetingTypes.get_active_meeting_types(user.id)

      # Should have created defaults
      assert result != []
    end

    test "defaults do not set calendar integration without booking target" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      _profile = insert(:profile, user: user, primary_calendar_integration_id: integration.id)

      result = MeetingTypes.get_active_meeting_types(user.id)

      assert result != []
      assert Enum.all?(result, &is_nil(&1.calendar_integration_id))
      assert Enum.all?(result, &is_nil(&1.target_calendar_id))
    end

    test "returns all meeting types including inactive ones" do
      user = insert(:user)
      _active_type = insert(:meeting_type, user: user, is_active: true)
      _inactive_type = insert(:meeting_type, user: user, is_active: false)

      result = MeetingTypes.get_all_meeting_types(user.id)

      assert length(result) == 2
    end
  end

  describe "when getting a specific meeting type" do
    test "returns meeting type when it exists for user" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      result = MeetingTypes.get_meeting_type(meeting_type.id, user.id)

      assert result.id == meeting_type.id
      assert result.user_id == user.id
    end

    test "returns nil when meeting type does not exist" do
      user = insert(:user)

      result = MeetingTypes.get_meeting_type(999_999, user.id)

      assert result == nil
    end

    test "returns nil when meeting type belongs to different user" do
      user1 = insert(:user)
      user2 = insert(:user)
      meeting_type = insert(:meeting_type, user: user1)

      result = MeetingTypes.get_meeting_type(meeting_type.id, user2.id)

      assert result == nil
    end
  end

  # =====================================
  # Creating Meeting Types Behaviors
  # =====================================

  describe "when creating a meeting type" do
    test "successfully creates with valid attributes" do
      user = insert(:user)

      attrs = %{
        name: "Quick Chat",
        duration_minutes: 15,
        description: "A brief conversation",
        icon: "hero-bolt",
        is_active: true,
        allow_video: false,
        user_id: user.id
      }

      assert {:ok, meeting_type} = MeetingTypes.create_meeting_type(attrs)

      assert meeting_type.name == "Quick Chat"
      assert meeting_type.duration_minutes == 15
      assert meeting_type.is_active == true
    end

    test "fails with missing required fields" do
      user = insert(:user)

      attrs = %{
        user_id: user.id
        # Missing name and duration_minutes
      }

      result = MeetingTypes.create_meeting_type(attrs)

      assert {:error, changeset} = result
      assert changeset.valid? == false
    end
  end

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
  end

  # =====================================
  # Updating Meeting Types Behaviors
  # =====================================

  describe "when updating a meeting type" do
    test "successfully updates existing meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Old Name")

      assert {:ok, updated} = MeetingTypes.update_meeting_type(meeting_type, %{name: "New Name"})

      assert updated.name == "New Name"
    end

    test "can change duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

      assert {:ok, updated} =
               MeetingTypes.update_meeting_type(meeting_type, %{duration_minutes: 45})

      assert updated.duration_minutes == 45
    end
  end

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

  # =====================================
  # Toggling Meeting Type Status Behaviors
  # =====================================

  describe "when toggling meeting type status" do
    test "activates an inactive meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, is_active: false)

      assert {:ok, toggled} = MeetingTypes.toggle_meeting_type(meeting_type.id, user.id)

      assert toggled.is_active == true
    end

    test "deactivates an active meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, is_active: true)

      assert {:ok, toggled} = MeetingTypes.toggle_meeting_type(meeting_type.id, user.id)

      assert toggled.is_active == false
    end

    test "returns not found for non-existent meeting type" do
      user = insert(:user)

      result = MeetingTypes.toggle_meeting_type(999_999, user.id)

      assert {:error, :not_found} = result
    end

    test "returns not found when meeting type belongs to different user" do
      user1 = insert(:user)
      user2 = insert(:user)
      meeting_type = insert(:meeting_type, user: user1)

      result = MeetingTypes.toggle_meeting_type(meeting_type.id, user2.id)

      assert {:error, :not_found} = result
    end
  end

  # =====================================
  # Deleting Meeting Types Behaviors
  # =====================================

  describe "when deleting a meeting type" do
    test "successfully deletes meeting type" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      assert {:ok, deleted} = MeetingTypes.delete_meeting_type(meeting_type)

      assert deleted.id == meeting_type.id

      # Verify it's actually deleted
      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id) == nil
    end
  end

  # =====================================
  # Duration String Behaviors
  # =====================================

  describe "when converting to duration string" do
    test "formats duration in minutes" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "30 Minutes", duration_minutes: 30)

      result = MeetingTypes.to_duration_string(meeting_type)

      assert result == "30-minutes"
    end

    test "handles various durations" do
      user = insert(:user)

      meeting_type_15 =
        insert(:meeting_type, user: user, name: "15 Minutes", duration_minutes: 15)

      meeting_type_60 =
        insert(:meeting_type, user: user, name: "60 Minutes", duration_minutes: 60)

      meeting_type_90 =
        insert(:meeting_type, user: user, name: "90 Minutes", duration_minutes: 90)

      assert MeetingTypes.to_duration_string(meeting_type_15) == "15-minutes"
      assert MeetingTypes.to_duration_string(meeting_type_60) == "60-minutes"
      assert MeetingTypes.to_duration_string(meeting_type_90) == "90-minutes"
    end
  end

  describe "when finding meeting type by slug" do
    test "finds matching meeting type" do
      user = insert(:user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Discovery Call",
          duration_minutes: 30,
          is_active: true
        )

      result = MeetingTypes.find_by_slug(user.id, "discovery-call")

      assert result.id == meeting_type.id
    end

    test "returns nil for non-matching slug" do
      user = insert(:user)

      _meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Discovery Call",
          duration_minutes: 30,
          is_active: true
        )

      result = MeetingTypes.find_by_slug(user.id, "other-call")

      assert result == nil
    end

    test "only finds active meeting types" do
      user = insert(:user)

      _inactive =
        insert(:meeting_type,
          user: user,
          name: "Inactive Call",
          duration_minutes: 30,
          is_active: false
        )

      active =
        insert(:meeting_type,
          user: user,
          name: "Active Call",
          duration_minutes: 45,
          is_active: true
        )

      result_inactive = MeetingTypes.find_by_slug(user.id, "inactive-call")
      result_active = MeetingTypes.find_by_slug(user.id, "active-call")

      assert result_inactive == nil
      assert result_active.id == active.id
    end
  end

  # Keep old tests for find_by_duration_string but update expectations
  describe "when finding meeting type by duration string (deprecated)" do
    test "finds matching meeting type by slug" do
      user = insert(:user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          name: "Quick Chat",
          duration_minutes: 30,
          is_active: true
        )

      result = MeetingTypes.find_by_duration_string(user.id, "quick-chat")

      assert result.id == meeting_type.id
    end
  end

  # =====================================
  # Duration Validation Behaviors
  # =====================================

  describe "when validating duration selection" do
    test "accepts valid duration from available types" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Intro", duration_minutes: 30)

      result = MeetingTypes.validate_duration_selection("intro", [meeting_type])

      assert result == :ok
    end

    test "rejects nil duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      result = MeetingTypes.validate_duration_selection(nil, [meeting_type])

      assert {:error, message} = result
      assert message =~ "select"
    end

    test "rejects empty duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      result = MeetingTypes.validate_duration_selection("", [meeting_type])

      assert {:error, message} = result
      assert message =~ "select"
    end

    test "rejects duration not in available types" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Intro", duration_minutes: 30)

      result = MeetingTypes.validate_duration_selection("other", [meeting_type])

      assert {:error, message} = result
      assert message =~ "Invalid"
    end
  end

  describe "when checking duration validity" do
    test "returns true for valid duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Quick", duration_minutes: 45)

      result = MeetingTypes.duration_valid?("quick", [meeting_type])

      assert result == true
    end

    test "returns false for invalid duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user, name: "Intro")

      result = MeetingTypes.duration_valid?("other", [meeting_type])

      assert result == false
    end

    test "returns false for non-binary duration" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      result = MeetingTypes.duration_valid?(123, [meeting_type])

      assert result == false
    end

    test "returns false for non-list available types" do
      result = MeetingTypes.duration_valid?("30min", nil)

      assert result == false
    end
  end

  # =====================================
  # List Meeting Types Behaviors
  # =====================================

  describe "when listing meeting types" do
    test "returns all meeting types for user" do
      user = insert(:user)
      _type1 = insert(:meeting_type, user: user, is_active: true)
      _type2 = insert(:meeting_type, user: user, is_active: false)

      result = MeetingTypes.list_meeting_types(user.id)

      assert length(result) == 2
    end

    test "creates defaults if user has no meeting types" do
      user = insert(:user)

      result = MeetingTypes.list_meeting_types(user.id)

      assert result != []
    end
  end

  describe "when getting meeting type by ID only" do
    test "returns meeting type when it exists" do
      user = insert(:user)
      meeting_type = insert(:meeting_type, user: user)

      result = MeetingTypes.get_meeting_type!(meeting_type.id)

      assert result.id == meeting_type.id
    end

    test "raises when meeting type does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        MeetingTypes.get_meeting_type!(999_999)
      end
    end
  end

  describe "when reordering meeting types" do
    test "reorders meeting types for a user" do
      user = insert(:user)

      mt1 = insert(:meeting_type, user: user, name: "Meeting A", sort_order: 0)
      mt2 = insert(:meeting_type, user: user, name: "Meeting B", sort_order: 1)
      mt3 = insert(:meeting_type, user: user, name: "Meeting C", sort_order: 2)

      # Reorder: B, C, A
      new_order = [mt2.id, mt3.id, mt1.id]

      assert {:ok, _} = MeetingTypes.reorder_meeting_types(user.id, new_order)

      # Verify new order
      types = MeetingTypes.get_all_meeting_types(user.id)
      assert Enum.at(types, 0).id == mt2.id
      assert Enum.at(types, 1).id == mt3.id
      assert Enum.at(types, 2).id == mt1.id
    end

    test "does not reorder other users' meeting types" do
      user1 = insert(:user)
      user2 = insert(:user)

      mt1 = insert(:meeting_type, user: user1, name: "User1 First", sort_order: 0)
      mt2 = insert(:meeting_type, user: user1, name: "User1 Second", sort_order: 1)

      # Try to reorder user1's types as user2
      new_order = [mt2.id, mt1.id]
      assert {:ok, _} = MeetingTypes.reorder_meeting_types(user2.id, new_order)

      # Verify user1's types remain unchanged
      types = MeetingTypes.get_all_meeting_types(user1.id)
      assert Enum.at(types, 0).id == mt1.id
      assert Enum.at(types, 1).id == mt2.id
    end

    test "handles empty meeting type list" do
      user = insert(:user)

      assert {:ok, _} = MeetingTypes.reorder_meeting_types(user.id, [])
    end
  end
end
