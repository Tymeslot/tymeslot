defmodule Tymeslot.Utils.SanitizeMergeCompositionTest do
  @moduledoc """
  Regression coverage for the refactored sanitise-merge sites
  (Calendar.Creation, VideoSettingsComponent add_integration,
  ServiceSettingsComponent meeting type form).

  Each test pairs the real validator / helper output with
  `SanitizeMerge.merge/2` to prove the refactor preserves the happy-path
  merged value. The merge function's own semantics — drop signals, empty
  strings, key precedence — are covered by `sanitize_merge_test.exs`.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Integrations.Calendar.InputValidation, as: CalendarInputValidation
  alias Tymeslot.Integrations.Video.InputValidation, as: VideoInputValidation
  alias Tymeslot.MeetingTypes.InputValidation, as: MeetingInputValidation
  alias Tymeslot.Utils.SanitizeMerge

  describe "Calendar.Creation sanitiser output" do
    test "preserves populated URL / username on the happy path" do
      params = %{
        "name" => "My Calendar",
        "provider" => "caldav",
        "url" => "https://cal.example.com",
        "username" => "alice",
        "password" => "correct horse battery staple",
        "calendar_paths" => "/cal1"
      }

      assert {:ok, sanitized} =
               CalendarInputValidation.validate_calendar_integration_form(params, metadata: %{})

      merged = SanitizeMerge.merge(params, sanitized)

      assert merged["url"] == "https://cal.example.com"
      assert merged["username"] == "alice"
      assert merged["calendar_paths"] == "/cal1"
    end
  end

  describe "VideoSettingsComponent add_integration" do
    test "preserves populated base_url and api_key through the merge" do
      params = %{
        "provider" => "mirotalk",
        "name" => "My Mirotalk",
        "api_key" => "abcdef12345678",
        "base_url" => "https://mirotalk.example.com"
      }

      assert {:ok, sanitized} =
               VideoInputValidation.validate_video_integration_form(params, metadata: %{})

      merged = SanitizeMerge.merge(params, sanitized)

      assert merged["base_url"] == "https://mirotalk.example.com"
      assert merged["api_key"] == "abcdef12345678"
    end
  end

  describe "ServiceSettingsComponent meeting type form" do
    test "empty string calendar_integration_id is preserved against a nil sanitiser" do
      # When the user submits "" for an optional id field, the validator
      # normalises it to nil. SanitizeMerge must not let that nil silently
      # overwrite the user's submitted value — "" is user-provided content,
      # not a drop signal.
      params = %{
        "name" => "Consultation",
        "duration" => "30",
        "description" => "",
        "icon" => "none",
        "meeting_mode" => "personal",
        "calendar_integration_id" => "",
        "target_calendar_id" => "",
        "reminder_config" => %{}
      }

      assert {:ok, sanitized} =
               MeetingInputValidation.validate_meeting_type_form(params, metadata: %{})

      merged = SanitizeMerge.merge(params, sanitized)

      assert merged["name"] == "Consultation"
      assert merged["duration"] == "30"
      assert merged["calendar_integration_id"] == ""
    end
  end
end
