defmodule Tymeslot.Integrations.Video.TemplateSyntaxTest do
  use ExUnit.Case, async: true
  @moduletag :video

  alias Tymeslot.Integrations.Video.TemplateSyntax

  describe "analyze/1 with valid templates" do
    test "recognizes valid template with {{meeting_id}}" do
      url = "https://jitsi.example.org/{{meeting_id}}"

      assert {:ok, :valid_template, preview, message} = TemplateSyntax.analyze(url)
      # Preview should contain 16-character hex hash
      assert preview =~ ~r|^https://jitsi.example.org/[a-f0-9]{16}$|
      assert message == "Template variable detected: {{meeting_id}}"
    end

    test "handles template in middle of URL" do
      url = "https://jitsi.example.org/room-{{meeting_id}}-session"

      assert {:ok, :valid_template, preview, _message} = TemplateSyntax.analyze(url)
      # Preview should contain 16-character hex hash between 'room-' and '-session'
      assert preview =~ ~r|^https://jitsi.example.org/room-[a-f0-9]{16}-session$|
    end

    test "handles template in query parameters" do
      url = "https://meet.example.com/room?id={{meeting_id}}"

      assert {:ok, :valid_template, preview, _message} = TemplateSyntax.analyze(url)
      # Preview should contain 16-character hex hash in query parameter
      assert preview =~ ~r|^https://meet.example.com/room\?id=[a-f0-9]{16}$|
    end
  end

  describe "analyze/1 with mismatched brackets" do
    test "detects opening double, closing single" do
      url = "https://jitsi.org/{{meeting_id)"

      assert {:warning, _type, preview, message} = TemplateSyntax.analyze(url)
      assert preview == url
      assert message =~ "Mismatched brackets"
      assert message =~ "{{meeting_id)"
    end

    test "detects opening single, closing double" do
      url = "https://jitsi.org/{meeting_id}}"

      assert {:warning, _type, preview, message} = TemplateSyntax.analyze(url)
      assert preview == url
      assert message =~ "Mismatched brackets"
      assert message =~ "{meeting_id}}"
    end

    test "detects curly-square bracket mismatch" do
      url = "https://jitsi.org/{{meeting_id]]"

      assert {:warning, :mismatched_curly_square, _preview, message} =
               TemplateSyntax.analyze(url)

      assert message =~ "{{meeting_id]]"
    end

    test "detects square-curly bracket mismatch" do
      url = "https://jitsi.org/[[meeting_id}}"

      assert {:warning, :mismatched_square_curly, _preview, message} =
               TemplateSyntax.analyze(url)

      assert message =~ "[[meeting_id}}"
    end
  end

  describe "analyze/1 with missing brackets" do
    test "detects missing closing brackets" do
      url = "https://jitsi.org/{{meeting_id"

      assert {:warning, :missing_closing_brackets, _preview, message} =
               TemplateSyntax.analyze(url)

      assert message =~ "Missing closing brackets"
    end

    test "detects missing opening brackets" do
      url = "https://jitsi.org/meeting_id}}"

      assert {:warning, :missing_opening_brackets, _preview, message} =
               TemplateSyntax.analyze(url)

      assert message =~ "Missing opening brackets"
    end
  end

  describe "analyze/1 with wrong bracket types" do
    test "detects single curly brackets with meeting_id" do
      url = "https://jitsi.org/{meeting_id}"

      assert {:warning, :single_curly_brackets, _preview, message} =
               TemplateSyntax.analyze(url)

      assert message =~ "double curly brackets"
      assert message =~ "{meeting_id}"
    end

    test "detects square brackets as mismatched" do
      # [[meeting_id]] is caught by mismatched brackets check
      url = "https://jitsi.org/[[meeting_id]]"

      assert {:warning, :mismatched_brackets, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "brackets"
    end

    test "detects parentheses" do
      url = "https://jitsi.org/((meeting_id))"

      assert {:warning, :parentheses, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "curly brackets"
      assert message =~ "((meeting_id))"
    end

    test "detects angle brackets" do
      url = "https://jitsi.org/<meeting_id>"

      assert {:warning, :angle_brackets, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "curly brackets"
    end
  end

  describe "analyze/1 with variable name issues" do
    test "detects hyphen instead of underscore" do
      url = "https://jitsi.org/{{meeting-id}}"

      assert {:warning, :hyphen_instead_of_underscore, _preview, message} =
               TemplateSyntax.analyze(url)

      assert message =~ "underscore"
      assert message =~ "{{meeting-id}}"
    end

    test "detects missing underscore" do
      url = "https://jitsi.org/{{meetingid}}"

      assert {:warning, :missing_underscore, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "underscore"
      assert message =~ "{{meetingid}}"
    end

    test "detects wrong case specifically" do
      url = "https://jitsi.org/{{MEETING_ID}}"

      assert {:warning, :wrong_case, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "lowercase"
      assert message =~ "{{meeting_id}}"
    end

    test "detects mixed case" do
      url = "https://jitsi.org/{{Meeting_Id}}"

      assert {:warning, :wrong_case, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "lowercase"
    end
  end

  describe "analyze/1 with unknown variables" do
    test "detects unknown variable with correct syntax" do
      url = "https://jitsi.org/{{room_id}}"

      assert {:warning, :unknown_variable, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "Unknown template variable"
      assert message =~ "{{meeting_id}}"
    end

    test "only {{meeting_id}} is supported - rejects {{user_id}}" do
      url = "https://jitsi.org/{{user_id}}"

      assert {:warning, :unknown_variable, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "Only {{meeting_id}} is supported"
    end

    test "only {{meeting_id}} is supported - rejects {{event_id}}" do
      url = "https://jitsi.org/{{event_id}}"

      assert {:warning, :unknown_variable, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "Only {{meeting_id}} is supported"
    end
  end

  describe "analyze/1 with no brackets" do
    test "detects meeting_id text without brackets" do
      url = "https://jitsi.org/meeting_id"

      assert {:warning, :no_brackets, _preview, message} = TemplateSyntax.analyze(url)
      assert message =~ "without brackets"
      assert message =~ "{{meeting_id}}"
    end
  end

  describe "analyze/1 with static URLs" do
    test "recognizes static URL without template" do
      url = "https://meet.example.com/my-permanent-room"

      assert {:ok, :static, returned_url, message} = TemplateSyntax.analyze(url)
      assert returned_url == url
      assert message =~ "Static URL"
      assert message =~ "same room"
    end

    test "handles static URL with query parameters" do
      url = "https://meet.example.com/room?key=value"

      assert {:ok, :static, returned_url, _message} = TemplateSyntax.analyze(url)
      assert returned_url == url
    end
  end

  describe "analyze/1 with empty or nil input" do
    test "returns empty state for empty string" do
      assert {:ok, :empty, "", message} = TemplateSyntax.analyze("")
      assert message == "Enter a URL to see a preview"
    end

    test "returns empty state for nil" do
      assert {:ok, :empty, "", message} = TemplateSyntax.analyze(nil)
      assert message == "Enter a URL to see a preview"
    end
  end

  describe "analyze/1 edge cases" do
    test "handles multiple template variables (only one is valid)" do
      url = "https://jitsi.org/{{meeting_id}}/{{meeting_id}}"

      # Should still be recognized as valid since it contains {{meeting_id}}
      assert {:ok, :valid_template, _preview, _message} = TemplateSyntax.analyze(url)
    end

    test "treats unknown variable with wrong brackets as static" do
      # {room_id} with single brackets and unknown variable is treated as static
      # because error checks are specific to "meeting_id"
      url = "https://jitsi.org/{room_id}"

      assert {:ok, :static, _preview, _message} = TemplateSyntax.analyze(url)
    end

    test "handles URLs with special characters" do
      url = "https://jitsi.example.org/room-{{meeting_id}}?param=value&foo=bar"

      assert {:ok, :valid_template, preview, _message} = TemplateSyntax.analyze(url)
      # Preview should contain 16-character hex hash
      assert preview =~ ~r|/room-[a-f0-9]{16}\?|
      assert preview =~ "?param=value&foo=bar"
    end

    test "handles very long URLs" do
      long_subdomain = String.duplicate("subdomain.", 10)
      url = "https://#{long_subdomain}example.org/{{meeting_id}}"

      assert {:ok, :valid_template, preview, _message} = TemplateSyntax.analyze(url)
      assert preview =~ long_subdomain
      # Preview should contain 16-character hex hash
      assert preview =~ ~r|/[a-f0-9]{16}$|
    end
  end

  describe "analyze/1 with template in fragment" do
    test "detects template in fragment position" do
      url = ~S"https://jitsi.org/room#{{meeting_id}}"

      assert {:warning, :template_in_fragment, _preview, message} =
               TemplateSyntax.analyze(url)

      assert message =~ "fragment"
      assert message =~ "aren't sent to servers"
    end

    test "detects template in fragment with query parameters" do
      url = ~S"https://jitsi.org/room?key=value#{{meeting_id}}"

      assert {:warning, :template_in_fragment, _preview, message} =
               TemplateSyntax.analyze(url)

      assert message =~ "fragment"
    end

    test "allows static fragment without template" do
      url = "https://jitsi.org/room#section"

      assert {:ok, :static, _url, _message} = TemplateSyntax.analyze(url)
    end

    test "allows template in path even when fragment exists" do
      url = ~S"https://jitsi.org/{{meeting_id}}#config"

      assert {:ok, :valid_template, preview, _message} = TemplateSyntax.analyze(url)
      # Should process template in path and keep static fragment
      assert preview =~ ~r|/[a-f0-9]{16}#config$|
    end
  end

  describe "analyze/1 warns on malformed tokens it used to pass" do
    test "single curly brackets in the wrong case" do
      url = "https://jitsi.org/{Meeting_ID}"

      assert {:warning, :single_curly_brackets, ^url, _message} = TemplateSyntax.analyze(url)
    end

    test "spaces inside double curly brackets" do
      url = "https://jitsi.org/{{ meeting_id }}"

      assert {:warning, :invalid_template_syntax, ^url, message} = TemplateSyntax.analyze(url)
      assert message == "Write the template variable exactly as {{meeting_id}}"
    end

    test "a stray malformed token next to a valid template" do
      url = "https://jitsi.org/{{meeting_id}}/{meeting_id}"

      assert {:warning, :single_curly_brackets, ^url, _message} = TemplateSyntax.analyze(url)
    end
  end

  @accepted_urls [
    {"a static URL", "https://meet.example.com/my-permanent-room"},
    {"a template in the path", "https://jitsi.example.org/{{meeting_id}}"},
    {"a template in the query", "https://meet.example.com/room?id={{meeting_id}}"},
    {"a decoded Teams meeting link",
     ~s(https://teams.microsoft.com/l/meetup-join/19:meeting_NjU4YTQ@thread.v2/0?context={"Tid":"72f988bf-86f1","Oid":"a1b2c3d4-e5f6"})},
    {"a bare meeting_id query parameter", "https://meet.example.com/room?meeting_id=1"},
    {"a static fragment", "https://jitsi.org/room#section"},
    {"a template in the path with a static fragment", "https://jitsi.org/{{meeting_id}}#config"},
    {"single curly brackets around another word", "https://jitsi.org/{room_id}"}
  ]

  @refused_urls [
    {"single curly brackets", "https://meet.jit.si/{meeting_id}",
     "Use double curly brackets: {{meeting_id}} not {meeting_id}"},
    {"the wrong case", "https://meet.jit.si/{{Meeting_ID}}",
     "Use lowercase: {{meeting_id}} not {{MEETING_ID}} or {{Meeting_Id}}"},
    {"spaces inside the brackets", "https://meet.jit.si/{{ meeting_id }}",
     "Write the template variable exactly as {{meeting_id}}"},
    {"single curly brackets in the wrong case", "https://meet.jit.si/{Meeting_ID}",
     "Use double curly brackets: {{meeting_id}} not {meeting_id}"},
    {"a hyphen inside single brackets", "https://meet.jit.si/{meeting-id}",
     "Write the template variable exactly as {{meeting_id}}"},
    {"a missing underscore", "https://meet.jit.si/{{meetingid}}",
     "Missing underscore: {{meeting_id}} not {{meetingid}}"},
    {"an unknown variable", "https://meet.jit.si/{{room}}",
     "Unknown template variable. Only {{meeting_id}} is supported"},
    {"square brackets", "https://meet.jit.si/[[meeting_id]]",
     "Mismatched brackets detected - use {{meeting_id}}"},
    {"angle brackets", "https://meet.jit.si/<meeting_id>",
     "Use curly brackets: {{meeting_id}} not <meeting_id>"},
    {"a template in the fragment", ~S"https://meet.jit.si/room#{{meeting_id}}",
     "Template in fragment (#) won't work - fragments aren't sent to servers. Use path instead: https://example.com/{{meeting_id}}"},
    {"a stray token next to a valid template", "https://meet.jit.si/{{meeting_id}}/{meeting_id}",
     "Use double curly brackets: {{meeting_id}} not {meeting_id}"}
  ]

  @other_malformed_urls [
    "https://jitsi.org/{{meeting_id)",
    "https://jitsi.org/{meeting_id}}",
    "https://jitsi.org/{{meeting_id]]",
    "https://jitsi.org/[[meeting_id}}",
    "https://jitsi.org/{{meeting_id",
    "https://jitsi.org/meeting_id}}",
    "https://jitsi.org/((meeting_id))",
    "https://jitsi.org/{{meeting-id}}",
    "https://jitsi.org/{{MEETING_ID}}",
    "https://jitsi.org/{{}}",
    "https://jitsi.org/(meeting id)",
    "https://jitsi.org/{{meeting_id}}{{room}}"
  ]

  describe "validate/1" do
    for {label, url} <- @accepted_urls do
      test "accepts #{label}" do
        assert TemplateSyntax.validate(unquote(url)) == :ok
      end
    end

    for {label, url, message} <- @refused_urls do
      test "refuses #{label}" do
        assert TemplateSyntax.validate(unquote(url)) == {:error, unquote(message)}
      end
    end
  end

  describe "validate/1 and analyze/1 agree" do
    test "every refused URL is shown as a warning carrying the same message" do
      disagreements =
        Enum.reject(@refused_urls, fn {_label, url, message} ->
          match?({:warning, _type, ^url, ^message}, TemplateSyntax.analyze(url))
        end)

      assert disagreements == []
    end

    test "every URL the analyzer flags as broken syntax is refused on save, with a warning" do
      refused_without_warning =
        Enum.reject(@other_malformed_urls, fn url ->
          TemplateSyntax.validate(url) != :ok and
            match?({:warning, _type, ^url, _message}, TemplateSyntax.analyze(url))
        end)

      assert length(@other_malformed_urls) == 12
      assert refused_without_warning == []
    end

    test "no accepted URL is shown as a blocking warning other than the bare meeting_id hint" do
      flagged =
        @accepted_urls
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(&match?({:warning, _type, _preview, _message}, TemplateSyntax.analyze(&1)))

      assert flagged == ["https://meet.example.com/room?meeting_id=1"]
    end
  end
end
