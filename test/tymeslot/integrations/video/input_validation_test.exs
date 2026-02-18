defmodule Tymeslot.Integrations.Video.InputValidationTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Integrations.Video.InputValidation

  describe "validate_video_integration_form/2 - mirotalk" do
    test "accepts valid mirotalk input" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meetings",
        "api_key" => "a-very-long-api-key-12345",
        "base_url" => "https://meet.example.com"
      }

      assert {:ok, sanitized} = InputValidation.validate_video_integration_form(params)
      assert sanitized["name"] == "Team Meetings"
      assert sanitized["api_key"] == "a-very-long-api-key-12345"
      assert sanitized["base_url"] == "https://meet.example.com"
    end

    test "rejects missing api_key" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meetings",
        "base_url" => "https://meet.example.com"
      }

      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :api_key)
    end

    test "rejects empty api_key" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meetings",
        "api_key" => "",
        "base_url" => "https://meet.example.com"
      }

      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :api_key)
    end

    test "rejects api_key shorter than 8 characters" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meetings",
        "api_key" => "short",
        "base_url" => "https://meet.example.com"
      }

      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :api_key)
    end

    test "rejects missing base_url" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meetings",
        "api_key" => "a-valid-api-key-12345"
      }

      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :base_url)
    end

    test "rejects base_url without a valid domain" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meetings",
        "api_key" => "a-valid-api-key-12345",
        "base_url" => "not-a-url"
      }

      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :base_url)
    end

    test "rejects localhost base_url" do
      params = %{
        "provider" => "mirotalk",
        "name" => "Team Meetings",
        "api_key" => "a-valid-api-key-12345",
        "base_url" => "http://localhost:8080"
      }

      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :base_url)
    end

    test "rejects missing name" do
      params = %{
        "provider" => "mirotalk",
        "api_key" => "a-valid-api-key-12345",
        "base_url" => "https://meet.example.com"
      }

      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :name)
    end
  end

  describe "validate_video_integration_form/2 - custom provider" do
    test "accepts valid custom video input" do
      params = %{
        "provider" => "custom",
        "name" => "My Video Tool",
        "custom_meeting_url" => "https://meet.example.com/room/abc123"
      }

      assert {:ok, sanitized} = InputValidation.validate_video_integration_form(params)
      assert sanitized["name"] == "My Video Tool"
      assert sanitized["custom_meeting_url"] == "https://meet.example.com/room/abc123"
    end

    test "rejects missing custom_meeting_url" do
      params = %{"provider" => "custom", "name" => "My Video Tool"}
      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :custom_meeting_url)
    end

    test "rejects empty custom_meeting_url" do
      params = %{"provider" => "custom", "name" => "My Video Tool", "custom_meeting_url" => ""}
      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :custom_meeting_url)
    end

    test "normalizes custom_meeting_url without protocol by adding https://" do
      params = %{
        "provider" => "custom",
        "name" => "My Video Tool",
        "custom_meeting_url" => "example.com/room"
      }

      assert {:ok, sanitized} = InputValidation.validate_video_integration_form(params)
      assert String.starts_with?(sanitized["custom_meeting_url"], "https://")
    end

    test "rejects localhost custom_meeting_url" do
      params = %{
        "provider" => "custom",
        "name" => "My Video Tool",
        "custom_meeting_url" => "http://localhost/room"
      }

      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :custom_meeting_url)
    end
  end

  describe "validate_video_integration_form/2 - unknown provider" do
    test "returns error for unknown provider" do
      params = %{"provider" => "zoom", "name" => "Zoom Meeting"}
      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :provider)
    end

    test "returns error for nil provider" do
      params = %{"name" => "Meeting"}
      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :provider)
    end
  end

  describe "validate_single_field/3" do
    test "validates :name field" do
      assert {:ok, "My Integration"} =
               InputValidation.validate_single_field(:name, "My Integration")

      assert {:error, _msg} = InputValidation.validate_single_field(:name, "")
    end

    test "validates :api_key field" do
      assert {:ok, "valid-api-key-12345"} =
               InputValidation.validate_single_field(:api_key, "valid-api-key-12345")

      assert {:error, _msg} = InputValidation.validate_single_field(:api_key, "short")
    end

    test "validates :base_url field" do
      assert {:ok, _url} =
               InputValidation.validate_single_field(:base_url, "https://meet.example.com")

      assert {:error, _msg} = InputValidation.validate_single_field(:base_url, "")
    end

    test "returns ok for unknown fields" do
      assert {:ok, nil} = InputValidation.validate_single_field(:unknown_field, "value")
    end
  end
end
