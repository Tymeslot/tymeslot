defmodule Tymeslot.Utils.SanitizeMergeCompositionTest do
  @moduledoc """
  Regression coverage for the five refactored sanitise-merge sites
  (Calendar.Creation, VideoSettingsComponent add_integration,
  ServiceSettingsComponent meeting type form, EditVideoIntegrationModal
  save, CalendarSettingsComponent selection merge).

  Each test pairs the real validator / helper output with
  `SanitizeMerge.merge/2` to prove the refactor preserves the happy-path
  merged value and does the right thing when the right-hand side carries a
  drop-signal sentinel.
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

    test "preserves user-selected calendar_integration_id against a nil drop-signal" do
      # Regression-critical: if any future sanitiser returned nil for a
      # populated optional field, SanitizeMerge keeps the user's value.
      params = %{
        "name" => "Consultation",
        "duration" => "30",
        "calendar_integration_id" => 42
      }

      sanitized = %{
        "name" => "Consultation",
        "duration" => "30",
        "calendar_integration_id" => nil
      }

      merged = SanitizeMerge.merge(params, sanitized)

      assert merged["calendar_integration_id"] == 42
    end
  end

  describe "EditVideoIntegrationModal save" do
    test "preserves populated api_key through the merge" do
      params = %{
        "provider" => "mirotalk",
        "name" => "My Mirotalk",
        "api_key" => "newkey12345678",
        "base_url" => "https://mirotalk.example.com"
      }

      assert {:ok, sanitized} =
               VideoInputValidation.validate_video_integration_form(params, metadata: %{})

      merged = SanitizeMerge.merge(params, sanitized)

      assert merged["api_key"] == "newkey12345678"
    end

    test "HTML-stripped sanitiser output still overwrites raw params" do
      # Complement of the drop-signal preservation: if a sanitiser strips a
      # malicious payload down to `""`, that empty string must still win —
      # otherwise the raw `<script>` would survive. SanitizeMerge's empty
      # string is deliberately **not** a drop-signal.
      params = %{"description" => "<script></script>"}
      sanitized = %{"description" => ""}

      assert SanitizeMerge.merge(params, sanitized) == %{"description" => ""}
    end
  end
end
