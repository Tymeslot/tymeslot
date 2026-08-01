defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig.TemplateAnalyzerTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig.TemplateAnalyzer

  describe "analyze/1 with valid templates" do
    test "recognizes valid template with {{meeting_id}}" do
      url = "https://jitsi.example.org/{{meeting_id}}"

      assert {:ok, :valid_template, preview, message} = TemplateAnalyzer.analyze(url)
      # Preview should contain 16-character hex hash
      assert preview =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
      assert message == "Template variable detected: {{meeting_id}}"
    end

    test "handles template in middle of URL" do
      url = "https://jitsi.example.org/room-{{meeting_id}}-session"

      assert {:ok, :valid_template, preview, _message} = TemplateAnalyzer.analyze(url)
      # Preview should contain 16-character hex hash between 'room-' and '-session'
      assert preview =~ ~r|^https://jitsi.example.org/room-[a-f0-9]{16}-session$|
    end

    test "handles template in query parameters" do
      url = "https://meet.example.com/room?id={{meeting_id}}"

      assert {:ok, :valid_template, preview, _message} = TemplateAnalyzer.analyze(url)
      # Preview should contain 16-character hex hash in query parameter
      assert preview =~ ~r|^https://meet.example.com/room\?id=[a-f0-9]{16}$|
    end
  end

  describe "analyze/1 with mismatched brackets" do
    test "detects opening double, closing single" do
      url = "https://jitsi.org/{{meeting_id)"

      assert {:warning, _type, preview, message} = TemplateAnalyzer.analyze(url)
      assert preview == url
      assert message =~ "Mismatched brackets"
      assert message =~ "{{meeting_id)"
    end

    test "detects opening single, closing double" do
      url = "https://jitsi.org/{meeting_id}}"

      assert {:warning, _type, preview, message} = TemplateAnalyzer.analyze(url)
      assert preview == url
      assert message =~ "Mismatched brackets"
      assert message =~ "{meeting_id}}"
    end

    test "detects curly-square bracket mismatch" do
      url = "https://jitsi.org/{{meeting_id]]"

      assert {:warning, :mismatched_curly_square, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "{{meeting_id]]"
    end

    test "detects square-curly bracket mismatch" do
      url = "https://jitsi.org/[[meeting_id}}"

      assert {:warning, :mismatched_square_curly, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "[[meeting_id}}"
    end
  end

  describe "analyze/1 with missing brackets" do
    test "detects missing closing brackets" do
      url = "https://jitsi.org/{{meeting_id"

      assert {:warning, :missing_closing_brackets, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "Missing closing brackets"
    end

    test "detects missing opening brackets" do
      url = "https://jitsi.org/meeting_id}}"

      assert {:warning, :missing_opening_brackets, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "Missing opening brackets"
    end
  end

  describe "analyze/1 with wrong bracket types" do
    test "detects single curly brackets with meeting_id" do
      url = "https://jitsi.org/{meeting_id}"

      assert {:warning, :single_curly_brackets, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "double curly brackets"
      assert message =~ "{meeting_id}"
    end

    test "detects square brackets as mismatched" do
      # [[meeting_id]] is caught by mismatched brackets check
      url = "https://jitsi.org/[[meeting_id]]"

      assert {:warning, :mismatched_brackets, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "brackets"
    end

    test "detects parentheses" do
      url = "https://jitsi.org/((meeting_id))"

      assert {:warning, :parentheses, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "curly brackets"
      assert message =~ "((meeting_id))"
    end

    test "detects angle brackets" do
      url = "https://jitsi.org/<meeting_id>"

      assert {:warning, :angle_brackets, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "curly brackets"
    end
  end

  describe "analyze/1 with variable name issues" do
    test "detects hyphen instead of underscore" do
      url = "https://jitsi.org/{{meeting-id}}"

      assert {:warning, :hyphen_instead_of_underscore, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "underscore"
      assert message =~ "{{meeting-id}}"
    end

    test "detects missing underscore" do
      url = "https://jitsi.org/{{meetingid}}"

      assert {:warning, :missing_underscore, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "underscore"
      assert message =~ "{{meetingid}}"
    end

    test "detects wrong case specifically" do
      url = "https://jitsi.org/{{MEETING_ID}}"

      assert {:warning, :wrong_case, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "lowercase"
      assert message =~ "{{meeting_id}}"
    end

    test "detects mixed case" do
      url = "https://jitsi.org/{{Meeting_Id}}"

      assert {:warning, :wrong_case, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "lowercase"
    end
  end

  describe "analyze/1 with unknown variables" do
    test "detects unknown variable with correct syntax" do
      url = "https://jitsi.org/{{room_id}}"

      assert {:warning, :unknown_variable, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "Unknown template variable"
      assert message =~ "{{meeting_id}}"
    end

    test "detects another unknown variable" do
      url = "https://jitsi.org/{{session_id}}"

      assert {:warning, :unknown_variable, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "{{meeting_id}}"
    end

    test "only {{meeting_id}} is supported - rejects {{user_id}}" do
      url = "https://jitsi.org/{{user_id}}"

      assert {:warning, :unknown_variable, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "Only {{meeting_id}} is supported"
    end

    test "only {{meeting_id}} is supported - rejects {{event_id}}" do
      url = "https://jitsi.org/{{event_id}}"

      assert {:warning, :unknown_variable, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "Only {{meeting_id}} is supported"
    end
  end

  describe "analyze/1 with no brackets" do
    test "detects meeting_id text without brackets" do
      url = "https://jitsi.org/meeting_id"

      assert {:warning, :no_brackets, _preview, message} = TemplateAnalyzer.analyze(url)
      assert message =~ "without brackets"
      assert message =~ "{{meeting_id}}"
    end
  end

  describe "analyze/1 with static URLs" do
    test "recognizes static URL without template" do
      url = "https://meet.example.com/my-permanent-room"

      assert {:ok, :static, returned_url, message} = TemplateAnalyzer.analyze(url)
      assert returned_url == url
      assert message =~ "Static URL"
      assert message =~ "same room"
    end

    test "handles static URL with query parameters" do
      url = "https://meet.example.com/room?key=value"

      assert {:ok, :static, returned_url, _message} = TemplateAnalyzer.analyze(url)
      assert returned_url == url
    end
  end

  describe "analyze/1 with empty or nil input" do
    test "returns empty state for empty string" do
      assert {:ok, :empty, "", message} = TemplateAnalyzer.analyze("")
      assert message == "Enter a URL to see a preview"
    end

    test "returns empty state for nil" do
      assert {:ok, :empty, "", message} = TemplateAnalyzer.analyze(nil)
      assert message == "Enter a URL to see a preview"
    end
  end

  describe "analyze/1 edge cases" do
    test "handles multiple template variables (only one is valid)" do
      url = "https://jitsi.org/{{meeting_id}}/{{meeting_id}}"

      # Should still be recognized as valid since it contains {{meeting_id}}
      assert {:ok, :valid_template, _preview, _message} = TemplateAnalyzer.analyze(url)
    end

    test "prioritizes valid template over other issues" do
      # If URL contains valid {{meeting_id}}, it should be recognized as valid
      # even if there are other patterns in the URL
      url = "https://jitsi.org/{{meeting_id}}/room"

      assert {:ok, :valid_template, _preview, _message} = TemplateAnalyzer.analyze(url)
    end

    test "treats unknown variable with wrong brackets as static" do
      # {room_id} with single brackets and unknown variable is treated as static
      # because error checks are specific to "meeting_id"
      url = "https://jitsi.org/{room_id}"

      assert {:ok, :static, _preview, _message} = TemplateAnalyzer.analyze(url)
    end

    test "handles URLs with special characters" do
      url = "https://jitsi.example.org/room-{{meeting_id}}?param=value&foo=bar"

      assert {:ok, :valid_template, preview, _message} = TemplateAnalyzer.analyze(url)
      # Preview should contain 16-character hex hash
      assert preview =~ ~r|/room-[a-f0-9]{16}\?|
      assert preview =~ "?param=value&foo=bar"
    end

    test "handles very long URLs" do
      long_subdomain = String.duplicate("subdomain.", 10)
      url = "https://#{long_subdomain}example.org/{{meeting_id}}"

      assert {:ok, :valid_template, preview, _message} = TemplateAnalyzer.analyze(url)
      assert preview =~ long_subdomain
      # Preview should contain 16-character hex hash
      assert preview =~ ~r|/[a-f0-9]{16}$|
    end
  end

  describe "analyze/1 with template in fragment" do
    test "detects template in fragment position" do
      url = ~S"https://jitsi.org/room#{{meeting_id}}"

      assert {:warning, :template_in_fragment, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "fragment"
      assert message =~ "aren't sent to servers"
    end

    test "detects template in fragment with query parameters" do
      url = ~S"https://jitsi.org/room?key=value#{{meeting_id}}"

      assert {:warning, :template_in_fragment, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "fragment"
    end

    test "allows static fragment without template" do
      url = "https://jitsi.org/room#section"

      assert {:ok, :static, _url, _message} = TemplateAnalyzer.analyze(url)
    end

    test "allows template in path even when fragment exists" do
      url = ~S"https://jitsi.org/{{meeting_id}}#config"

      assert {:ok, :valid_template, preview, _message} = TemplateAnalyzer.analyze(url)
      # Should process template in path and keep static fragment
      assert preview =~ ~r|/[a-f0-9]{16}#config$|
    end

    test "fragment check has priority over other syntax errors" do
      # Even with wrong syntax, fragment position should be detected first
      url = ~S"https://jitsi.org/room#{{meeting_id}}"

      assert {:warning, :template_in_fragment, _preview, message} =
               TemplateAnalyzer.analyze(url)

      assert message =~ "fragment"
    end
  end
end
