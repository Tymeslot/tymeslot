defmodule Tymeslot.Security.MeetingSettingsInputProcessorTest do
  @moduletag :security
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.MeetingSettingsInputProcessor

  describe "validate_meeting_type_form" do
  @moduletag :security
    test "accepts valid input" do
      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "description" => "A quick chat",
        "icon" => "hero-bolt",
        "meeting_mode" => "video"
      }

      assert {:ok, sanitized} = MeetingSettingsInputProcessor.validate_meeting_type_form(params)
      assert sanitized["name"] == "Coffee Chat"
      assert sanitized["duration"] == "30"
      assert sanitized["icon"] == "hero-bolt"
      assert sanitized["meeting_mode"] == "video"
    end

    test "rejects invalid icon" do
      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "description" => "A quick chat",
        "icon" => "invalid-icon",
        "meeting_mode" => "video"
      }

      assert {:error, errors} = MeetingSettingsInputProcessor.validate_meeting_type_form(params)
      assert errors[:icon] == "Invalid icon selected"
    end

    test "rejects invalid meeting mode" do
      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "description" => "A quick chat",
        "icon" => "hero-bolt",
        "meeting_mode" => "telepathy"
      }

      assert {:error, errors} = MeetingSettingsInputProcessor.validate_meeting_type_form(params)
      assert errors[:meeting_mode] == "Invalid meeting mode selected"
    end

    test "enforces duration limits" do
      params = %{
        "name" => "Coffee Chat",
        # Over 480
        "duration" => "485",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = MeetingSettingsInputProcessor.validate_meeting_type_form(params)
      assert errors[:duration] == "Duration cannot exceed 8 hours (480 minutes)"
    end

    test "validates reminder_config" do
      params = %{
        "name" => "Reminder Test",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "reminder_config" => [
          %{"value" => "30", "unit" => "minutes"},
          # Duplicate
          %{"value" => "30", "unit" => "minutes"}
        ]
      }

      assert {:error, errors} = MeetingSettingsInputProcessor.validate_meeting_type_form(params)
      assert errors[:reminder_config] == "Reminder settings must be unique"

      params =
        Map.put(params, "reminder_config", [
          %{"value" => "-5", "unit" => "minutes"}
        ])

      assert {:error, errors} = MeetingSettingsInputProcessor.validate_meeting_type_form(params)
      assert errors[:reminder_config] == "Reminder settings must include valid values and units"
    end
  end

  describe "validate_buffer_minutes" do
    test "accepts valid buffer" do
      assert {:ok, 15} = MeetingSettingsInputProcessor.validate_buffer_minutes("15")
    end

    test "rejects buffer over 120" do
      assert {:error, "Buffer minutes cannot exceed 120"} =
               MeetingSettingsInputProcessor.validate_buffer_minutes("121")
    end

    test "rejects negative buffer" do
      assert {:error, "Buffer minutes must be at least 0"} =
               MeetingSettingsInputProcessor.validate_buffer_minutes("-1")
    end
  end

  describe "validate_advance_booking_days" do
    test "accepts valid days" do
      assert {:ok, 90} = MeetingSettingsInputProcessor.validate_advance_booking_days("90")
    end

    test "rejects days over 365" do
      assert {:error, "Advance booking days cannot exceed 365"} =
               MeetingSettingsInputProcessor.validate_advance_booking_days("366")
    end
  end

  describe "validate_min_advance_hours" do
    test "accepts valid hours" do
      assert {:ok, 24} = MeetingSettingsInputProcessor.validate_min_advance_hours("24")
    end

    test "rejects hours over 168" do
      assert {:error, "Minimum advance hours cannot exceed 168"} =
               MeetingSettingsInputProcessor.validate_min_advance_hours("169")
    end
  end
end
