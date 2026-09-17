defmodule Tymeslot.Integrations.Video.InputValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

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

  describe "validate_video_integration_form/2 - custom meeting URL template syntax" do
    defp custom_params(url),
      do: %{"provider" => "custom", "name" => "My Video Tool", "custom_meeting_url" => url}

    test "refuses a malformed meeting ID placeholder on the meeting URL field" do
      assert {:error, %{custom_meeting_url: message}} =
               InputValidation.validate_video_integration_form(
                 custom_params("https://meet.jit.si/{meeting_id}")
               )

      assert message == "Use double curly brackets: {{meeting_id}} not {meeting_id}"
    end

    test "refuses a percent-encoded placeholder that decodes to a malformed one" do
      assert {:error, %{custom_meeting_url: message}} =
               InputValidation.validate_video_integration_form(
                 custom_params("https://meet.jit.si/%7Bmeeting_id%7D")
               )

      assert message == "Use double curly brackets: {{meeting_id}} not {meeting_id}"
    end

    test "refuses an angle-bracket placeholder before sanitising strips it" do
      assert {:error, %{custom_meeting_url: message}} =
               InputValidation.validate_video_integration_form(
                 custom_params("https://meet.jit.si/<meeting_id>")
               )

      assert message == "Use curly brackets: {{meeting_id}} not <meeting_id>"
    end

    test "accepts a correctly written template" do
      url = "https://meet.jit.si/{{meeting_id}}"

      assert {:ok, %{"custom_meeting_url" => ^url}} =
               InputValidation.validate_video_integration_form(custom_params(url))
    end

    test "accepts a static URL" do
      url = "https://meet.jit.si/my-room"

      assert {:ok, %{"custom_meeting_url" => ^url}} =
               InputValidation.validate_video_integration_form(custom_params(url))
    end

    test "accepts a permanent Teams link whose context decodes to braces" do
      url =
        "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NjU4YTQ%40thread.v2/0?context=%7b%22Tid%22%3a%2272f988bf%22%2c%22Oid%22%3a%22a1b2c3d4%22%7d"

      assert {:ok, %{"custom_meeting_url" => sanitized}} =
               InputValidation.validate_video_integration_form(custom_params(url))

      assert sanitized =~ ~s(context={"Tid":"72f988bf","Oid":"a1b2c3d4"})
    end

    test "validate_single_field/3 refuses the same malformed placeholder" do
      assert InputValidation.validate_single_field(
               :custom_meeting_url,
               "https://meet.jit.si/{meeting_id}"
             ) == {:error, "Use double curly brackets: {{meeting_id}} not {meeting_id}"}
    end
  end

  describe "validate_video_integration_form/2 - kmeet" do
    test "accepts a name and returns only the name" do
      params = %{
        "provider" => "kmeet",
        "name" => "  Team kMeet  ",
        "base_url" => "https://elsewhere.example.com"
      }

      assert {:ok, sanitized} = InputValidation.validate_video_integration_form(params)
      assert sanitized == %{"name" => "Team kMeet"}
    end

    test "rejects a missing name" do
      params = %{"provider" => "kmeet", "name" => ""}
      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :name)
    end
  end

  describe "validate_video_integration_form/2 - jitsi" do
    test "trims the server URL and credentials and leaves their checks to the provider" do
      params = %{
        "provider" => "jitsi",
        "name" => "  Our Jitsi  ",
        "base_url" => " https://meet.example.com ",
        "client_id" => " tymeslot ",
        "client_secret" => " <secret&with?symbols> "
      }

      assert {:ok, sanitized} = InputValidation.validate_video_integration_form(params)

      assert sanitized == %{
               "name" => "Our Jitsi",
               "base_url" => "https://meet.example.com",
               "client_id" => "tymeslot",
               "client_secret" => "<secret&with?symbols>",
               "remove_token_authentication" => false
             }
    end

    test "turns the removal checkbox into a boolean" do
      params = %{
        "provider" => "jitsi",
        "name" => "Our Jitsi",
        "remove_token_authentication" => "true"
      }

      assert {:ok, %{"remove_token_authentication" => true} = sanitized} =
               InputValidation.validate_video_integration_form(params)

      refute Map.has_key?(sanitized, "client_secret")
    end

    # A credential key in the result means "supplied", which clears
    # `needs_reauth` on update; a blank field must not claim that.
    test "leaves blank credentials out" do
      params = %{
        "provider" => "jitsi",
        "name" => "Our Jitsi",
        "base_url" => "https://meet.example.com",
        "client_id" => "",
        "client_secret" => "   "
      }

      assert {:ok, sanitized} = InputValidation.validate_video_integration_form(params)
      refute Map.has_key?(sanitized, "client_id")
      refute Map.has_key?(sanitized, "client_secret")
    end

    test "strips a null byte from the server URL" do
      params = %{
        "provider" => "jitsi",
        "name" => "Our Jitsi",
        "base_url" => "https://meet.example.com/a\0b"
      }

      assert {:ok, %{"base_url" => "https://meet.example.com/ab"}} =
               InputValidation.validate_video_integration_form(params)
    end

    test "strips a null byte from the App ID and App secret and leaves the rest of the secret alone" do
      params = %{
        "provider" => "jitsi",
        "name" => "Our Jitsi",
        "base_url" => "https://meet.example.com",
        "client_id" => "tyme\0slot",
        "client_secret" => "<secret\0&symbols>"
      }

      assert {:ok, sanitized} = InputValidation.validate_video_integration_form(params)
      assert sanitized["client_id"] == "tymeslot"
      assert sanitized["client_secret"] == "<secret&symbols>"
    end

    test "rejects a missing name" do
      params = %{"provider" => "jitsi", "name" => "", "base_url" => "https://meet.example.com"}
      assert {:error, errors} = InputValidation.validate_video_integration_form(params)
      assert Map.has_key?(errors, :name)
    end
  end

  describe "validate_video_integration_form/2 - nextcloud_talk" do
    @talk_params %{
      "provider" => "nextcloud_talk",
      "name" => "Team Talk",
      "base_url" => " https://cloud.example.com ",
      "client_id" => " organiser ",
      "client_secret" => " Abcde-Fghij-Klmno-Pqrst-Uvwxy "
    }

    test "trims the server, login name and app password and passes nothing else on" do
      assert {:ok, sanitized} =
               InputValidation.validate_video_integration_form(
                 Map.put(@talk_params, "remove_token_authentication", "true")
               )

      assert sanitized == %{
               "name" => "Team Talk",
               "base_url" => "https://cloud.example.com",
               "client_id" => "organiser",
               "client_secret" => "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
             }
    end

    # A credential key in the result means "supplied"; the edit dialog's blank
    # app password field must keep the stored one instead.
    test "leaves a blank app password out" do
      assert {:ok, sanitized} =
               InputValidation.validate_video_integration_form(%{
                 @talk_params
                 | "client_secret" => "   "
               })

      refute Map.has_key?(sanitized, "client_secret")
    end

    test "strips a null byte from the server, login name and app password" do
      assert {:ok, sanitized} =
               InputValidation.validate_video_integration_form(%{
                 @talk_params
                 | "base_url" => "https://cloud.example.com/nc\0",
                   "client_id" => "organ\0iser",
                   "client_secret" => "Abcde\0-Fghij"
               })

      assert sanitized["base_url"] == "https://cloud.example.com/nc"
      assert sanitized["client_id"] == "organiser"
      assert sanitized["client_secret"] == "Abcde-Fghij"
    end

    test "still requires a name" do
      assert {:error, %{name: _message}} =
               InputValidation.validate_video_integration_form(%{@talk_params | "name" => ""})
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
