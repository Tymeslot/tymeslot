defmodule Tymeslot.Security.VideoInputProcessorTest do
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.VideoInputProcessor

  describe "validate_video_integration_form/2 for mirotalk" do
    test "accepts valid mirotalk input" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meeting",
        "api_key" => "a-very-long-api-key-12345",
        "base_url" => "https://meet.jit.si"
      }

      assert {:ok, sanitized} = VideoInputProcessor.validate_video_integration_form(params)
      assert sanitized["name"] == "Team Meeting"
      assert sanitized["api_key"] == "a-very-long-api-key-12345"
      assert sanitized["base_url"] == "https://meet.jit.si"
    end

    test "rejects missing api key" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meeting",
        "base_url" => "https://meet.jit.si"
      }

      assert {:error, errors} = VideoInputProcessor.validate_video_integration_form(params)
      assert errors[:api_key] == "API key is required"
    end

    test "rejects short api key" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meeting",
        "api_key" => "short",
        "base_url" => "https://meet.jit.si"
      }

      assert {:error, errors} = VideoInputProcessor.validate_video_integration_form(params)
      assert errors[:api_key] == "API key must be at least 8 characters"
    end
  end

  describe "validate_video_integration_form/2 for custom" do
    test "accepts valid custom input" do
      params = %{
        "provider" => "custom",
        "name" => "Personal Meeting Room",
        "custom_meeting_url" => "https://meet.example.com/my-room"
      }

      assert {:ok, sanitized} = VideoInputProcessor.validate_video_integration_form(params)
      assert sanitized["name"] == "Personal Meeting Room"
      assert sanitized["custom_meeting_url"] == "https://meet.example.com/my-room"
    end

    test "rejects invalid URL" do
      params = %{
        "provider" => "custom",
        "name" => "Personal Meeting Room",
        "custom_meeting_url" => "not-a-url"
      }

      assert {:error, errors} = VideoInputProcessor.validate_video_integration_form(params)
      assert errors[:custom_meeting_url] == "Only HTTP and HTTPS URLs are allowed"
    end
  end

  describe "validate_video_integration_form/2 with unknown provider" do
    test "rejects unknown provider" do
      params = %{"provider" => "unknown_provider"}

      assert {:error, %{provider: "Unknown video provider"}} =
               VideoInputProcessor.validate_video_integration_form(params)
    end
  end
end
