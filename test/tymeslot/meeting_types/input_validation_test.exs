defmodule Tymeslot.MeetingTypes.InputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types

  alias Tymeslot.MeetingTypes.InputValidation

  describe "validate_meeting_type_form/2" do
    test "accepts valid meeting type form" do
      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "description" => "A quick chat",
        "icon" => "hero-bolt",
        "meeting_mode" => "video"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["name"] == "Coffee Chat"
      assert sanitized["duration"] == "30"
      assert sanitized["icon"] == "hero-bolt"
      assert sanitized["meeting_mode"] == "video"
    end

    test "returns error for missing name" do
      params = %{"duration" => "30", "icon" => "hero-bolt", "meeting_mode" => "personal"}
      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :name)
    end

    test "returns error for missing duration" do
      params = %{"name" => "Coffee Chat", "icon" => "hero-bolt", "meeting_mode" => "personal"}
      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :duration)
    end

    test "returns error for invalid icon" do
      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "icon" => "not-a-real-icon",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :icon)
    end

    test "returns error for invalid meeting mode" do
      params = %{
        "name" => "Coffee Chat",
        "duration" => "30",
        "icon" => "hero-bolt",
        "meeting_mode" => "hologram"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :meeting_mode)
    end

    test "defaults icon to 'none' when nil" do
      params = %{"name" => "Chat", "duration" => "30", "meeting_mode" => "personal"}
      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["icon"] == "none"
    end

    test "defaults meeting_mode to 'personal' when nil" do
      params = %{"name" => "Chat", "duration" => "30", "icon" => "none"}
      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["meeting_mode"] == "personal"
    end

    test "accumulates multiple field errors" do
      params = %{}
      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :name)
      assert Map.has_key?(errors, :duration)
    end
  end

  describe "validate_meeting_type_form/2 - duration constraints" do
    test "rejects duration below 5 minutes" do
      params = %{
        "name" => "Chat",
        "duration" => "4",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :duration)
    end

    test "rejects duration above 480 minutes" do
      params = %{
        "name" => "Chat",
        "duration" => "481",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :duration)
    end

    test "rejects duration not divisible by 5" do
      params = %{
        "name" => "Chat",
        "duration" => "17",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :duration)
    end

    test "accepts minimum valid duration (5 minutes)" do
      params = %{
        "name" => "Chat",
        "duration" => "5",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, _sanitized} = InputValidation.validate_meeting_type_form(params)
    end

    test "accepts maximum valid duration (480 minutes)" do
      params = %{
        "name" => "Chat",
        "duration" => "480",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, _sanitized} = InputValidation.validate_meeting_type_form(params)
    end
  end

  describe "validate_meeting_type_form/2 - slot_interval" do
    test "accepts a blank slot interval (means: same as meeting length)" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "slot_interval" => "",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["slot_interval"] == ""
    end

    test "accepts a missing slot interval (means: same as meeting length)" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["slot_interval"] == ""
    end

    test "accepts a valid slot interval" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "slot_interval" => "15",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["slot_interval"] == "15"
    end

    test "rejects a slot interval below 5 minutes" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "slot_interval" => "4",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert errors[:slot_interval] == "Slot interval must be at least 5 minutes"
    end

    test "rejects a slot interval above 480 minutes" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "slot_interval" => "481",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert errors[:slot_interval] == "Slot interval cannot exceed 480 minutes"
    end
  end

  describe "validate_meeting_type_form/2 - description" do
    test "accepts optional empty description" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "description" => ""
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["description"] == ""
    end

    test "rejects description exceeding 500 characters" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "description" => String.duplicate("a", 501)
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :description)
    end
  end

  describe "validate_meeting_type_form/2 - reminder_config" do
    test "accepts nil reminder_config" do
      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "reminder_config" => nil
      }

      assert {:ok, sanitized} = InputValidation.validate_meeting_type_form(params)
      assert sanitized["reminder_config"] == []
    end

    test "rejects more than 3 reminders" do
      reminders =
        Jason.encode!([
          %{"value" => 1, "unit" => "hours"},
          %{"value" => 2, "unit" => "hours"},
          %{"value" => 3, "unit" => "hours"},
          %{"value" => 4, "unit" => "hours"}
        ])

      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "reminder_config" => reminders
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :reminder_config)
    end

    test "rejects duplicate reminders" do
      reminders =
        Jason.encode!([
          %{"value" => 1, "unit" => "hours"},
          %{"value" => 1, "unit" => "hours"}
        ])

      params = %{
        "name" => "Chat",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal",
        "reminder_config" => reminders
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert Map.has_key?(errors, :reminder_config)
    end
  end

  describe "validate_buffer_minutes/2" do
    test "accepts valid buffer (0)" do
      assert {:ok, 0} = InputValidation.validate_buffer_minutes("0")
    end

    test "accepts valid buffer (60)" do
      assert {:ok, 60} = InputValidation.validate_buffer_minutes("60")
    end

    test "accepts maximum buffer (120)" do
      assert {:ok, 120} = InputValidation.validate_buffer_minutes("120")
    end

    test "rejects negative buffer" do
      assert {:error, _msg} = InputValidation.validate_buffer_minutes("-1")
    end

    test "rejects buffer exceeding 120" do
      assert {:error, _msg} = InputValidation.validate_buffer_minutes("121")
    end

    test "rejects non-numeric input" do
      assert {:error, _msg} = InputValidation.validate_buffer_minutes("lots")
    end
  end

  describe "validate_advance_booking_days/2" do
    test "accepts valid advance days (1)" do
      assert {:ok, 1} = InputValidation.validate_advance_booking_days("1")
    end

    test "accepts valid advance days (90)" do
      assert {:ok, 90} = InputValidation.validate_advance_booking_days("90")
    end

    test "accepts maximum advance days (365)" do
      assert {:ok, 365} = InputValidation.validate_advance_booking_days("365")
    end

    test "rejects zero advance days" do
      assert {:error, _msg} = InputValidation.validate_advance_booking_days("0")
    end

    test "rejects advance days exceeding 365" do
      assert {:error, _msg} = InputValidation.validate_advance_booking_days("366")
    end

    test "rejects non-numeric input" do
      assert {:error, _msg} = InputValidation.validate_advance_booking_days("many")
    end
  end

  describe "validate_min_advance_hours/2" do
    test "accepts zero hours (no advance notice required)" do
      assert {:ok, 0} = InputValidation.validate_min_advance_hours("0")
    end

    test "accepts valid advance hours (24)" do
      assert {:ok, 24} = InputValidation.validate_min_advance_hours("24")
    end

    test "accepts maximum advance hours (168 = 1 week)" do
      assert {:ok, 168} = InputValidation.validate_min_advance_hours("168")
    end

    test "rejects negative hours" do
      assert {:error, _msg} = InputValidation.validate_min_advance_hours("-1")
    end

    test "rejects hours exceeding 168" do
      assert {:error, _msg} = InputValidation.validate_min_advance_hours("169")
    end

    test "rejects non-numeric input" do
      assert {:error, _msg} = InputValidation.validate_min_advance_hours("tomorrow")
    end
  end

  describe "validate_meeting_type_form/2 - names that produce empty slugs" do
    test "rejects name consisting only of special characters" do
      params = %{
        "name" => "!!!",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert errors.name =~ "at least one letter or number"
    end

    test "rejects name consisting only of punctuation" do
      params = %{
        "name" => "....",
        "duration" => "30",
        "icon" => "none",
        "meeting_mode" => "personal"
      }

      assert {:error, errors} = InputValidation.validate_meeting_type_form(params)
      assert errors.name =~ "at least one letter or number"
    end
  end
end
